import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTabs
import Testing

/// Cmd-. stops a loading page (Safari, Chrome) and Cmd-Shift-C copies the
/// page's URL (Arc), in WebKit and Chromium tabs, through catalog actions.
@MainActor
@Suite(.serialized)
struct BrowserStopAndCopyURLTests {
    typealias M = KeyOwnershipMatrixTests

    @Test func pageChordsResolveToStopAndCopyURL() throws {
        let services = M.services()
        for id: ActionID in ["browserStop", "browser.copyURL"] { services.registry.bind(id, invoke: { _ in }) }
        let page = M.Surface(name: "page", focus: M.page)
        let stop = try KeyInterceptionTests.key(".", keyCode: 47, [.command])
        let copy = try KeyInterceptionTests.key("c", keyCode: 8, [.command, .shift])
        #expect(M.owner(services, stop, page) == .action("browserStop"))
        #expect(M.owner(services, copy, page) == .action("browser.copyURL"))
        // A terminal keeps Cmd-Shift-C (no browser there).
        let terminal = M.Surface(name: "terminal", focus: M.terminal)
        #expect(M.owner(services, copy, terminal) != .action("browser.copyURL"))
    }
}
