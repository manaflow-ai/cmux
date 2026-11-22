import AppKit
@testable import CmuxNextAgentPane
import CmuxNextApps
import Testing

/// Message actions (`cmux.chat.action/1`): the rows the installed extensions add to a message's
/// menu, as the page reports them with the message. With none the menu is exactly as before; a
/// pick hands the app, the action and the message to the daemon's `apps-chat-action`.
@Suite(.serialized)
@MainActor
struct AgentPaneChatActionsMenuTests {
    static let report: [String: Any] = [
        "rowId": "a1", "sessionId": "s1", "text": "Done: fixed.", "markdown": "Done: **fixed**.",
    ]
    static let chatActions: [String: Any] = [
        "message": ["id": "a1", "role": "assistant", "text": "Done: **fixed**.", "session": "s1"],
        "rows": [
            ["app": "local/notes", "id": "save", "title": "Save to Notes", "symbol": "note.text"],
            ["app": "local/notes", "id": "translate", "title": "Translate"],
        ],
    ]

    static func titles(_ report: [String: Any], picked: ((String, String, AppChatMessage) -> Void)? = nil) -> (NSMenu, [String]) {
        _ = NSApplication.shared
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: AgentPaneMessageTarget(report: report), devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in }, chatAction: picked ?? { _, _, _ in }))
        return (menu, menu.items.map { $0.isSeparatorItem ? "—" : $0.title })
    }

    @Test func withNoExtensionActionsTheMenuIsUnchanged() {
        var empty = Self.report
        empty["chatActions"] = ["message": ["id": "a1", "role": "assistant", "text": "x"], "rows": [Any]()]
        #expect(AgentPaneMessageTarget(report: empty)?.chatActions == nil)
        #expect(Self.titles(empty).1 == Self.titles(Self.report).1)
    }

    @Test func anExtensionsActionsShowAsTheirOwnGroupAndAPickSendsTheMessage() throws {
        var report = Self.report
        report["chatActions"] = Self.chatActions
        var picks: [(String, String, AppChatMessage)] = []
        let (menu, titles) = Self.titles(report) { picks.append(($0, $1, $2)) }
        let plain = Self.titles(Self.report).1
        let save = try #require(titles.firstIndex(of: "Save to Notes"))
        #expect(titles[save + 1] == "Translate")
        #expect(titles[save - 1] == "—")
        // Every row of the menu without extensions keeps its place around the new group.
        #expect(titles.filter { $0 != "Save to Notes" && $0 != "Translate" } .count == plain.count + 1)
        let item = try #require(menu.items.first { $0.title == "Save to Notes" })
        #expect(item.image != nil)
        _ = (item.target as? AgentPaneMenuAction)?.run()
        #expect(picks.count == 1)
        #expect(picks.first?.0 == "local/notes")
        #expect(picks.first?.1 == "save")
        #expect(picks.first?.2 == AppChatMessage(id: "a1", role: "assistant", text: "Done: **fixed**.", session: "s1"))
    }
}
