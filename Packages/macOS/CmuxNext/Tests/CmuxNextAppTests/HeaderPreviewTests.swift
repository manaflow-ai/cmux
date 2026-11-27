import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The chat header's Preview button (cx-00n1, Claude Code desktop's preview toggle): it owns a browser
/// tab beside the chat on the local page the chat's last turn started or mentioned. The first click
/// opens it beside the chat, the second closes it, and the button is lit while it is open. Runs the
/// header's path against a store whose layout the actions change as the daemon would, and the page's
/// `pane.action` message as the App decodes it.
@MainActor
struct HeaderPreviewTests {
    typealias Row = HeaderSplitOrderTests.Row
    static let page = "http://localhost:5173/"

    @Test func previewOpensTheChatsPageBesideItAndClosesIt() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("preview", toggles: toggles, url: Self.page)
        #expect(row.order == ["chat", "browser"])
        let opened = row.invocations["openBrowser"]
        #expect(opened?["url"]?.stringValue == Self.page)
        #expect(opened?.besideCaller == true)
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["preview"])
        row.click("preview", toggles: toggles, url: Self.page)
        #expect(row.order == ["chat"])
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == [])
    }

    @Test func previewUsesTheChatAsItsPlacementSourceAfterATerminal() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        row.click("preview", toggles: toggles, url: Self.page)
        #expect(row.invocations["openBrowser"]?.target?.id == row.chat)
        #expect(row.invocations["openBrowser"]?.newColumnBeside == true)
    }

    /// Browser and Preview both open browser tabs: each button keeps its own, wherever the user moves them.
    @Test func browserAndPreviewEachCloseTheirOwnTab() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("preview", toggles: toggles, url: Self.page)
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.order == ["chat", "browser", "browser"])
        let preview = row.tabs[1], browser = row.tabs[2]
        row.move(2, to: 1)
        row.click("preview", toggles: toggles, url: Self.page)
        #expect(row.tabs == [row.chat, browser])
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["splitBrowserRight"])
        #expect(!row.tabs.contains(preview))
    }

    /// The page names the preview; only a local page reaches the App, as for the preview card.
    @Test func thePageNamesAWebPageToPreview() {
        let message = { (url: String) in
            AgentPaneRequest(body: ["method": "pane.action", "params": ["id": "preview", "url": url, "mode": "toggle"]])
        }
        guard case .preview(let url, let toggle) = message(Self.page) else {
            Issue.record("pane.action preview did not decode")
            return
        }
        #expect(url == Self.page && toggle)
        for address in ["file:///etc/passwd", "https://example.com/", "http://user:secret@localhost:5173/"] {
            guard case .unsupported = message(address) else {
                Issue.record("\(address) decoded as a preview")
                continue
            }
        }
    }
}
