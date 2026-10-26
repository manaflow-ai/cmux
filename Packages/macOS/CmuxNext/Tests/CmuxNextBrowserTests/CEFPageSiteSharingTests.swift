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

    private static func arguments(forkAPI: Int32, caps: [CEFSwitches.PageSiteCap]) -> [String] {
        CEFSwitches.current(forkAPIVersion: forkAPI, rendererPaths: forkAPI >= CEFForkFeatures.rendererPathsForkAPI,
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

    @Test func aForkThatReadsTheSwitchGetsTheExactTable() {
        let arguments = Self.arguments(forkAPI: CEFForkFeatures.pageSiteSharingForkAPI, caps: CEFPageSchemes.siteCaps(Self.table))
        #expect(Self.sharingSwitches(arguments) == ["cmux-page-scheme-process-per-site=cmux.agent:8,cmux.cloud:8,cmux.history:8"])
    }

    /// The renderer-path fork (29) and the API 31 and 32 trains have no reader: the switch would do
    /// nothing there, and a later fork could read a stale grammar from it.
    @Test(arguments: [Int32(0), 24, 29, 31, 32])
    func anOlderForkNeverGetsTheSwitch(forkAPI: Int32) {
        let arguments = Self.arguments(forkAPI: forkAPI, caps: CEFPageSchemes.siteCaps(Self.table))
        #expect(Self.sharingSwitches(arguments).isEmpty, "\(arguments)")
    }

    /// The feature off: the app's table has no cap, so there is no switch on any fork.
    @Test func aTableWithNoCapsGivesNoSwitch() {
        let off = Self.table.mapValues { entry in
            var entry = entry
            entry.mainFrameCap = nil
            return entry
        }
        #expect(CEFPageSchemes.siteCaps(off).isEmpty)
        let arguments = Self.arguments(forkAPI: CEFForkFeatures.pageSiteSharingForkAPI, caps: CEFPageSchemes.siteCaps(off))
        #expect(Self.sharingSwitches(arguments).isEmpty, "\(arguments)")
    }
}
