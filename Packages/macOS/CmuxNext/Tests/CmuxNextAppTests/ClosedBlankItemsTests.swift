@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Recently Closed leaves out what reopening gives nothing back for (Leo 2026-10-11: it was full of
/// "workspace-35 about:blank" and "about:blank about:blank" rows): a tab the daemon marks `empty`
/// (an untouched New Tab page) and a tab, screen or workspace made only of those. A chat is kept
/// as a browser tab on `about:blank` too, but unmarked: it stays, named without the placeholder. A
/// workspace that kept a real tab stays, and its line names that tab, not the New Tab page beside it.
@MainActor
struct ClosedBlankItemsTests {
    private static let newTabPage = """
        {"kind":"browser","name":"about:blank","cwd":null,"url":"about:blank","browser_profile_id":null,"pinned":false,"empty":true}
        """
    private static let chat = """
        {"kind":"browser","name":"Fix the flaky upload test","cwd":"/Users/you/src/cmux","url":"about:blank","browser_profile_id":null,"pinned":false}
        """
    private static let untitledChat = """
        {"kind":"browser","name":"about:blank","cwd":"/Users/you/src/relay","url":"about:blank","browser_profile_id":null,"pinned":false}
        """
    private static let terminal = """
        {"kind":"terminal","name":null,"cwd":"/Users/you/src/cmux","url":null,"browser_profile_id":null,"pinned":false}
        """

    /// One closed item as `closed.list` lists it. A tab item carries its tab's name, as the daemon
    /// records it.
    private static func closed(_ kind: String, name: String? = nil, _ tabs: String...) throws -> ClosedItem {
        let label = name.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id":"closed_1","kind":"\(kind)","name":\(label),"workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":1,
         "screens":[{"name":null,"tabs":[\(tabs.joined(separator: ","))]}],"window":null,"member_count":1,"members":[]}
        """
        return try JSONDecoder().decode(ClosedItem.self, from: Data(json.utf8))
    }

    @Test func untouchedNewTabPagesAndTheirWorkspacesAreLeftOut() throws {
        let pages = InternalPageTabStore()
        let shown = try [
            ("New Tab page", Self.closed("tab", name: "about:blank", Self.newTabPage)),
            ("workspace of New Tab pages", Self.closed("workspace", name: "workspace-35", Self.newTabPage, Self.newTabPage)),
            ("empty workspace", Self.closed("workspace", name: "workspace-36")),
            ("terminal", Self.closed("tab", Self.terminal)),
            ("chat", Self.closed("tab", name: "Fix the flaky upload test", Self.chat)),
            ("untitled chat", Self.closed("tab", name: "about:blank", Self.untitledChat)),
            ("workspace with a terminal", Self.closed("workspace", name: "workspace-7", Self.newTabPage, Self.terminal)),
        ].filter { HistoryService.isWorthReopening($0.1) }.map { name, item in
            let text = HistoryService.daemonClosedText(item, pages: pages)
            return "\(name): \(text.title) · \(text.detail ?? "-")"
        }
        #expect(shown == [
            "terminal: /Users/you/src/cmux · /Users/you/src/cmux",
            "chat: Fix the flaky upload test · /Users/you/src/cmux",
            "untitled chat: /Users/you/src/relay · /Users/you/src/relay",
            "workspace with a terminal: workspace-7 · /Users/you/src/cmux",
        ])
    }
}
