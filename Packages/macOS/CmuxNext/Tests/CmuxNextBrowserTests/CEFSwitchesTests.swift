import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The New Tab and every agent chat are one site (`cmux-page://cmux.agent`). Chrome puts at most 2 main frames
/// of a site in one renderer (ProcessPerSiteMainFrameThreshold, content_features.cc), so 5 chats took 3
/// renderers. With the default-off feature `agentPageRendererSharing`, the agent site's entry in PL-memory's
/// page-scheme switch raises that site's cap. Only a fork whose switch reads the cap table gets it, and only
/// with the renderer paths, where no page holds a DevTools session that would end the sharing.
@Suite struct CEFSwitchesTests {
    private func arguments(forkAPI: Int32, rendererPaths: Bool = true, cap: Int? = 8) -> [String] {
        let features = CEFForkFeatures(forkAPIVersion: forkAPI, shimHasRendererPaths: rendererPaths)
        return CEFSwitches.current(forkAPIVersion: forkAPI, rendererPaths: features.rendererPaths,
                                   bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
                                   agentPageMainFrameCap: cap).arguments
    }

    private func pageSchemeArguments(_ arguments: [String]) -> [String] {
        arguments.filter { $0 == CEFSwitches.pageSchemeProcessPerSite || $0.hasPrefix(CEFSwitches.pageSchemeProcessPerSite + "=") }
    }

    @Test func theForkWithTheCapTableGetsTheAgentSiteEntry() {
        #expect(pageSchemeArguments(arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI))
                == ["cmux-page-scheme-process-per-site=cmux.agent:8"])
    }

    /// API 29 and 30 have the renderer paths but no cap table: the switch would be unknown there.
    @Test(arguments: [Int32(28), 29, CEFSwitches.pageSiteSharingForkAPI - 1])
    func aForkBeforeTheCapTableGetsNoEntry(forkAPI: Int32) {
        #expect(pageSchemeArguments(arguments(forkAPI: forkAPI)).isEmpty)
    }

    @Test func aShimWithoutTheRendererPathsGetsNoEntry() {
        #expect(pageSchemeArguments(arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI, rendererPaths: false)).isEmpty)
    }

    @Test func theFeatureOffGetsNoEntry() {
        #expect(pageSchemeArguments(arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI, cap: nil)).isEmpty)
    }

    /// The feature's `mainFrames` param sets the cap; nothing else in the switches changes with it.
    @Test func theFeatureParamSetsTheCap() {
        let four = arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI, cap: 4)
        #expect(pageSchemeArguments(four) == ["cmux-page-scheme-process-per-site=cmux.agent:4"])
        #expect(four.filter { !$0.hasPrefix(CEFSwitches.pageSchemeProcessPerSite) }
                == arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI, cap: nil))
    }

    /// The entry names the agent site, not the whole scheme: settings, viewers and passwords keep their own
    /// process reuse. The value parses as `<site>:<mainFrames>`, comma-joined, the format the fork reads.
    @Test func theValueListsOnlyTheAgentSite() throws {
        let argument = try #require(pageSchemeArguments(arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI)).first)
        let caps = try #require(Self.parse(value: String(argument.dropFirst(CEFSwitches.pageSchemeProcessPerSite.count + 1))))
        #expect(caps == [CEFSwitches.PageSiteCap(site: "cmux.agent", mainFrames: 8)])
        #expect(caps.allSatisfy { FirstPartyPages.ids.contains($0.site) })
    }

    @Test func severalSitesJoinWithCommas() {
        let caps = [CEFSwitches.PageSiteCap(site: "cmux.agent", mainFrames: 8), .init(site: "settings.privileged", mainFrames: 8)]
        let argument = CEFSwitches.pageSchemeProcessPerSiteArgument(caps)
        #expect(argument == "cmux-page-scheme-process-per-site=cmux.agent:8,settings.privileged:8")
        #expect(Self.parse(value: String(argument.dropFirst(CEFSwitches.pageSchemeProcessPerSite.count + 1))) == caps)
    }

    /// The value grammar: one or more `<site>:<mainFrames>` joined by `,`; a site is a non-empty host with no
    /// `:`, `,` or `/`; a cap is a whole number of at least 1. Nil for anything else.
    private static func parse(value: String) -> [CEFSwitches.PageSiteCap]? {
        var caps: [CEFSwitches.PageSiteCap] = []
        for entry in value.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains("/"),
                  let frames = Int(parts[1]), frames >= 1 else { return nil }
            caps.append(.init(site: String(parts[0]), mainFrames: frames))
        }
        return caps.isEmpty ? nil : caps
    }
}
