import AppKit
@testable import CmuxNextBrowser
import Testing

/// User 2026-10-20: "cmd click on links needs to always open in the right". A click mapped to
/// `linkPlacement` asks the host for a tab in the pane right of the page in both engines; a script's
/// request (no user gesture) keeps Chrome's background tab.
struct CmdClickLinkPlacementTests {
    private func linkPlacement() throws -> BrowserLinkAction {
        try #require(BrowserLinkAction(rawValue: "linkPlacement"), "there is no pane-on-the-right link action")
    }

    private func isLinkPlacement(_ disposition: BrowserNewTabDisposition?) -> Bool {
        disposition.map { String(describing: $0) } == "linkPlacement"
    }

    @Test func chromiumCommandClickAsksForThePaneOnTheRight() throws {
        let mapping = BrowserLinkClickMapping(cmdClick: try linkPlacement())
        let placement = CEFLinkClicks.placement(for: .newBackgroundTab, userGesture: true, click: nil, now: 0, mapping: mapping)
        guard case .tab(let disposition) = placement else { Issue.record("no tab: \(placement)"); return }
        #expect(isLinkPlacement(disposition))
    }

    @Test func aScriptsBackgroundTabKeepsChromesDefault() throws {
        let mapping = BrowserLinkClickMapping(cmdClick: try linkPlacement())
        #expect(CEFLinkClicks.placement(for: .newBackgroundTab, userGesture: false, click: nil, now: 0, mapping: mapping) == .tab(.backgroundTab))
    }

    @Test func webKitCommandClickAsksForThePaneOnTheRight() throws {
        let click = WebKitLinkClick(flags: .command, button: 0, mapping: BrowserLinkClickMapping(cmdClick: try linkPlacement()))
        guard case .open(let disposition) = click else { Issue.record("no new tab: \(click)"); return }
        #expect(isLinkPlacement(disposition))
    }

    /// `BrowserLinkClickMapping.chrome` is what a script's request follows: Chrome's own defaults.
    @Test func chromesMappingKeepsTheBackgroundTab() {
        #expect(BrowserLinkClickMapping.chrome.cmdClick == .backgroundTab)
    }
}
