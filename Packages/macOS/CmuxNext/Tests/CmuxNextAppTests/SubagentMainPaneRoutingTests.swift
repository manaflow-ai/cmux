import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp

/// Review of #27789 at 84718cf2: a chat docked as its screen's main pane is usually narrower than two
/// chat widths, so the subagent width check chose a tab in the chat's own pane before main pane
/// layout could put the first subagent in the column on its right, where it went before. Main pane
/// layout now decides the first open; the width check applies only where a new split would be made.
@MainActor
struct SubagentMainPaneRoutingTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The main pane opens placement asked for (chat, focus).
    @MainActor private final class Asked {
        var mainPane: [(chat: String, focus: Bool)] = []
    }

    /// Chat tab `chat`, `width` points wide, wired as the app wires one; its main pane open answers
    /// `placed` (nil: the chat is not its screen's main pane) and makes tab `created` when it places one.
    private func chat(_ chat: String, width: CGFloat, placed: Bool?) -> (model: AgentPaneModel, asked: Asked, tabs: AgentTabStore) {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        let asked = Asked()
        tabs.openInMainPane = { target, focus, _, made, _ in
            asked.mainPane.append((chat: target, focus: focus))
            if placed == true { made?("subagent-tab") }
            return placed
        }
        tabs.locate = { _ in nil }
        // Nothing on the chat's right yet: the column RightColumnPlacement reads has only the chat's width.
        tabs.rightColumn = { _ in .init(sourceWidth: width) }
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        tabs.wireHeader(model, key: chat)
        return (model, asked, tabs)
    }

    @Test func aNarrowMainPaneChatsFirstSubagentGoesToTheColumnOnItsRight() throws {
        // 600 pt: too narrow to halve (480 pt floor), the docked width of a main pane chat.
        let (model, asked, tabs) = chat("chat-tab", width: 600, placed: true)
        let header = try #require(model.header)
        let session = "main-\(UUID().uuidString)"
        #expect(header.openSubagent(session, "reviewer", false))
        #expect(asked.mainPane.map(\.chat) == ["chat-tab"], "the width check kept main pane layout from placing it in the column on its right")
        #expect(asked.mainPane.map(\.focus) == [false])
        #expect(AgentSubagentPanes.session("\(session):chat-tab").tab(for: "reviewer", isOpen: { _ in true }) == "subagent-tab")
        withExtendedLifetime(tabs) {}
    }

    @Test func aNarrowChatOutsideMainPaneLayoutKeepsTheTabInItsOwnPane() throws {
        // Not a main pane chat: main pane layout declines, and the width check stands (no split under the floor).
        let (model, asked, tabs) = chat("chat-tab", width: 600, placed: nil)
        let header = try #require(model.header)
        // Main pane layout is asked first and declines; the open falls to the chat's own pane, which this test has none of.
        #expect(!header.openSubagent("plain-\(UUID().uuidString)", "reviewer", false))
        #expect(asked.mainPane.map(\.chat) == ["chat-tab"])
        withExtendedLifetime(tabs) {}
    }
}
