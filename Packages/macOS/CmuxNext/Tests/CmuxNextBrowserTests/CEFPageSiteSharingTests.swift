@testable import CmuxNextBrowser
import Foundation
import Testing

/// PL-memory's `cmux-page-scheme-process-per-site` (p07-memory 049): Chrome gives every New Tab Page one
/// renderer (ChromeContentBrowserClient::ShouldUseProcessPerSite); cmux pages whose group shares a
/// renderer get the same through the fork's page-scheme table, which caps each shared renderer at 8 main
/// frames. The switch goes only to a fork that reads it and names only the pages that share.
@MainActor @Suite struct CEFPageSiteSharingTests {
    private static let root = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/pages/x")
    private static let cap = CEFPageSchemes.sharedRendererMainFrames

    /// The app's table with sharing on: the agent page and two privileged pages share, the diff page
    /// (`solo`) and passwords (`secrets`) do not.
    private static let table: [String: CEFPageSchemes.Entry] = [
        "cmux.history": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", mainFrameCap: cap),
        "cmux.agent": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", mainFrameCap: cap),
        "cmux.cloud": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", mainFrameCap: cap),
        "cmux.diff": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", dynamicPrefixes: ["__patch"], entry: "diff-page.html"),
        "cmux.passwords": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'"),
    ]

    /// The same table with `pageProcessGroups` on: each sharing page also names its group.
    private static let grouped: [String: CEFPageSchemes.Entry] = table.reduce(into: [:]) { out, item in
        var entry = item.value
        if entry.mainFrameCap != nil { entry.processGroup = item.key == "cmux.agent" ? "agent" : "privileged" }
        out[item.key] = entry
    }

    private static func arguments(forkAPI: Int32, rendererPaths: Bool? = nil, caps: [CEFSwitches.PageSiteCap]) -> [String] {
        CEFSwitches.current(forkAPIVersion: forkAPI, rendererPaths: rendererPaths ?? (forkAPI >= CEFForkFeatures.rendererPathsForkAPI),
                            bundleIdentifier: "com.cmuxterm.app.next", environment: [:], pageSiteCaps: caps).arguments
    }

    private static func sharingSwitches(_ arguments: [String]) -> [String] {
        arguments.filter { $0.hasPrefix(CEFSwitches.pageSchemeProcessPerSite) }
    }

    @Test func theTableNamesEverySharingPageByHostAndNoOther() {
        let caps = CEFPageSchemes.siteCaps(Self.table)
        #expect(caps == [
            CEFSwitches.PageSiteCap(site: "cmux.agent", mainFrames: 8),
            CEFSwitches.PageSiteCap(site: "cmux.cloud", mainFrames: 8),
            CEFSwitches.PageSiteCap(site: "cmux.history", mainFrames: 8),
        ], "a solo or secrets page got an entry, or the order depends on the dictionary: \(caps)")
    }

    /// A host entry shares only between pages of one host; the group entry is what lets History and
    /// Cloud share once the fork registers their group (webui-DESIGN.md 3.2).
    @Test func eachGroupOfASharingPageGetsItsOwnEntry() {
        let caps = CEFPageSchemes.siteCaps(Self.grouped)
        #expect(caps.map(\.site) == ["agent", "cmux.agent", "cmux.cloud", "cmux.history", "privileged"], "\(caps)")
        #expect(caps.allSatisfy { $0.mainFrames == 8 })
    }

    @Test func aForkThatReadsTheSwitchGetsTheExactTable() {
        let arguments = Self.arguments(forkAPI: CEFForkFeatures.pageSiteSharingForkAPI, caps: CEFPageSchemes.siteCaps(Self.table))
        #expect(Self.sharingSwitches(arguments) == ["cmux-page-scheme-process-per-site=cmux.agent:8,cmux.cloud:8,cmux.history:8"])
    }

    /// The fork train (manaflow-ai/cef `cp/p13-webui-086`) gives p13-webui-011, the switch's
    /// reader, API 42: a fork at that number must get the switch.
    @Test func theTrainsForkGetsTheSwitch() {
        let arguments = Self.arguments(forkAPI: 42, caps: CEFPageSchemes.siteCaps(Self.table))
        #expect(Self.sharingSwitches(arguments).count == 1, "\(arguments)")
    }

    /// The renderer-path fork (29), the API 31 trains and every number below 42 have no reader: the switch
    /// would do nothing there. 32 is p03-rendering-042's resize fence, 38-41 are the other p13 exports.
    @Test(arguments: [Int32(0), 24, 29, 31, 32, 37, 41])
    func anOlderForkNeverGetsTheSwitch(forkAPI: Int32) {
        let arguments = Self.arguments(forkAPI: forkAPI, caps: CEFPageSchemes.siteCaps(Self.table))
        #expect(Self.sharingSwitches(arguments).isEmpty, "\(arguments)")
    }

    /// A shim without the renderer paths keeps a DevTools session on every page, and the fork never
    /// shares a renderer with a DevTools agent: the switch would do nothing.
    @Test func noRendererPathsGivesNoSwitch() {
        let arguments = Self.arguments(forkAPI: CEFForkFeatures.pageSiteSharingForkAPI, rendererPaths: false,
                                       caps: CEFPageSchemes.siteCaps(Self.table))
        #expect(Self.sharingSwitches(arguments).isEmpty, "\(arguments)")
    }

    /// The feature off: the app's table has no cap, so there is no switch on any fork.
    @Test func aTableWithNoCapsGivesNoSwitch() {
        let off = Self.grouped.mapValues { entry in
            var entry = entry
            entry.mainFrameCap = nil
            return entry
        }
        #expect(CEFPageSchemes.siteCaps(off).isEmpty)
        let arguments = Self.arguments(forkAPI: CEFForkFeatures.pageSiteSharingForkAPI, caps: CEFPageSchemes.siteCaps(off))
        #expect(Self.sharingSwitches(arguments).isEmpty, "\(arguments)")
    }
}
