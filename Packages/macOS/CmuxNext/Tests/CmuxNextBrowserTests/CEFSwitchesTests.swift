import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Bench builds replay recorded pages with Web Page Replay (p12-perf-process task 221): the browser
/// process takes `host-resolver-rules` and `ignore-certificate-errors-spki-list` from
/// `CMUX_NEXT_BENCH_CEF_SWITCHES`, for a development or bench bundle, and nothing else from it.
@Suite struct CEFSwitchesTests {
    /// The rules Web Page Replay's README passes: ports and commas inside the value.
    static let rules = "host-resolver-rules=MAP *:80 127.0.0.1:8080,MAP *:443 127.0.0.1:8081,EXCLUDE localhost"
    static let spki = "ignore-certificate-errors-spki-list=PhrPvGIaAMmd29hj8BCZOq096yj7uMpRNHpn5PDxI6I="

    private func switches(bundle: String, bench: String, extra: [String: String] = [:]) -> [String] {
        CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: bundle,
                            environment: extra.merging(["CMUX_NEXT_BENCH_CEF_SWITCHES": bench]) { _, new in new }).arguments
    }

    @Test(arguments: ["com.cmuxterm.app.debug.bench-tag", "com.cmuxterm.app.next.dev"])
    func aBenchBundleTakesTheReplaySwitches(bundle: String) {
        let arguments = switches(bundle: bundle, bench: "--\(Self.rules)\n\(Self.spki)\n")
        #expect(arguments.contains(Self.rules))
        #expect(arguments.contains(Self.spki))
    }

    @Test func theBenchPathDropsEveryOtherSwitch() {
        let bench = [
            Self.rules,
            "remote-debugging-port=9222",
            "enable-features=BackForwardCache",
            "disable-gpu",
            "no-sandbox=1",
            "host-resolver-rules=",
            "ignore-certificate-errors-spki-list",
        ].joined(separator: "\n")
        #expect(CEFSwitches.benchSwitches(bench) == [Self.rules])
        let arguments = switches(bundle: "com.cmuxterm.app.debug.bench-tag", bench: bench)
        #expect(!arguments.contains("remote-debugging-port=9222"))
        #expect(!arguments.contains("enable-features=BackForwardCache"))
        #expect(!arguments.contains("disable-gpu"))
        #expect(!arguments.contains { $0.hasPrefix("no-sandbox") })
        #expect(arguments.filter { $0.hasPrefix("host-resolver-rules") } == [Self.rules])
    }

    /// A shipped bundle id never takes them, also not with the mock keychain variable a CI run sets.
    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.next"])
    func aShippedBundleIgnoresTheVariable(bundle: String) {
        let arguments = switches(bundle: bundle, bench: "\(Self.rules)\n\(Self.spki)", extra: ["CMUX_MOCK_KEYCHAIN": "1"])
        #expect(!arguments.contains { $0.hasPrefix("host-resolver-rules") || $0.hasPrefix("ignore-certificate-errors-spki-list") })
    }

    /// The bench list is newline-separated: the diagnostic list's colon would cut the rules apart.
    @Test func aColonInsideAValueStaysInTheSwitch() {
        #expect(CEFSwitches.benchSwitches(Self.rules) == [Self.rules])
        #expect(CEFSwitches.benchSwitches(nil).isEmpty)
        #expect(CEFSwitches.benchSwitches("\r\n\(Self.spki)\r\n") == [Self.spki])
    }
}

/// The New Tab and every agent chat are one site (`cmux-page://cmux.agent`). Chrome puts at most 2 main frames
/// of a site in one renderer (ProcessPerSiteMainFrameThreshold, content_features.cc), so 5 chats took 3
/// renderers. With the default-off feature `agentPageRendererSharing`, the agent site's entry in PL-memory's
/// page-scheme switch raises that site's cap. Only a fork whose switch reads the cap table gets it, and only
/// with the renderer paths, where no page holds a DevTools session that would end the sharing.
@Suite struct CEFSwitchesAgentPageSiteTests {
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
