import AppKit
import Testing
@testable import CmuxNextAgentPane

/// cx-a7r at the menu boundary (the page's right-click report into the native menu): a message in
/// a turn that forks offers Open in Side Chat after Fork from Here when the page reports that the
/// chat opens a side chat, and choosing it runs the page's side chat action (`chat.side`, the chat
/// menu's New side chat) through that turn.
@Suite
@MainActor
struct AgentPaneSideChatMenuTests {
    static func menu(report: [String: Any], page: @escaping (String, [String: String]) -> Void = { _, _ in }) -> NSMenu {
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: AgentPaneMessageTarget(report: report), devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in }, page: page))
        return menu
    }

    @Test func anEarlierTurnsReplyOpensASideChatThroughThatTurn() throws {
        var ran: [(name: String, params: [String: String])] = []
        let menu = Self.menu(report: ["text": "Done.", "markdown": "Done.", "forkSeq": 3, "sideChat": true]) {
            ran.append(($0, $1))
        }
        let titles = menu.items.map(\.title)
        let fork = try #require(titles.firstIndex(of: AgentPaneMenuStrings.forkFromHere), "\(titles)")
        let side = try #require(titles.firstIndex(of: AgentPaneMenuStrings.openInSideChat), "\(titles)")
        #expect(side == fork + 1)
        let item = menu.items[side]
        _ = (item.target as? NSObject)?.perform(item.action)
        #expect(ran.map(\.name) == ["chat.side"])
        #expect(ran.first?.params == ["throughSeq": "3"])
    }

    @Test func aChatThatOpensNoSideChatOnlyForks() {
        let titles = Self.menu(report: ["text": "Done.", "markdown": "Done.", "forkSeq": 3]).items.map(\.title)
        #expect(titles.contains(AgentPaneMenuStrings.forkFromHere))
        #expect(!titles.contains(AgentPaneMenuStrings.openInSideChat))
    }

    @Test func aTurnThatDoesNotForkOffersNoSideChat() {
        let titles = Self.menu(report: ["text": "Done.", "markdown": "Done.", "sideChat": true]).items.map(\.title)
        #expect(!titles.contains(AgentPaneMenuStrings.openInSideChat))
    }
}
