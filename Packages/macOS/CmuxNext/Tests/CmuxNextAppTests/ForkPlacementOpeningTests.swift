import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo, 2026-11-07: "our forking behavior, it's nice and it doesn't tear the screen and it loads fast and it
/// goes as people would expect forking chats should go." Every Fork To destination opens the fork in one
/// way, chosen by ``AgentForkDestination/opening``: in its new split (right, below), as a tab in the chat's
/// pane (New Tab), or made in the chat's pane and moved (the rest). A moved fork used to be listed in the
/// chat's strip on its way, and a column's or row's fork was focused in the chat's pane before its move
/// landed, so the chat's pane showed the fork and then the chat again. Now every moved fork is held out of
/// the chat's strip (``OutboundTab``) from the gesture on.
@MainActor @Suite(.serialized) struct ForkPlacementOpeningTests {
    @MainActor private final class Seen {
        var creates: [ConversationTabSplit?] = []
        var held: [String] = []
        let (heard, hear) = AsyncStream<Void>.makeStream()
    }

    private static let host = "install:fork-placement-test"

    /// One chat tab alone on its screen; agent tab creates are faked (recorded, then refused).
    private static func chat() throws -> (AppServices, AgentTabStore, String, Seen) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let capabilities = [DaemonCapability.agentSessionTabs, .conversationTabSplit, .splitClientKeys, .splitClientSplitID]
        let list = capabilities.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"fork-placement","generation":"g1","capabilities":["# + list + "]}"
        store.noteHandshake(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-chat", harness: "codex"))
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        let key = try #require(store.pane(PaneID(rawValue: 1))?.tabs.first?.id)
        let tabs = services.agentTabs
        tabs.localHost = host
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        tabs.locate = { [weak services] _ in services.map { (pane: PaneID(rawValue: 1), daemon: $0.daemon) } }
        tabs.rightColumn = { _ in .init(sourceWidth: 1400) }
        tabs.serially = { _, turn in turn({}); return true }
        tabs.openInMainPane = { _, _, _, _, _ in nil }
        let seen = Seen()
        tabs.holdOutbound = { chat in
            seen.held.append(chat)
            return nil
        }
        tabs.create = { _, _, _, _, _, split in
            seen.creates.append(split)
            seen.hear.yield()
            throw CancellationError()
        }
        return (services, tabs, key, seen)
    }

    @Test(arguments: AgentForkDestination.allCases)
    func eachDestinationOpensTheForkOneWay(destination: AgentForkDestination) {
        let expected: AgentForkDestination.Opening = switch destination {
        case .right, .down: .split
        case .tab: .tab
        case .left, .up, .columnRight, .columnLeft, .row, .workspace, .window: .moved
        }
        #expect(destination.opening == expected)
    }

    /// Every destination: the fork shows where it goes, and the chat's pane never lists it on its way there.
    @Test(.timeLimit(.minutes(1)), arguments: AgentForkDestination.allCases)
    func theChatsPaneNeverShowsAForkGoingElsewhere(destination: AgentForkDestination) async throws {
        let (services, tabs, chat, seen) = try Self.chat()
        let store = services.daemon.store

        #expect(tabs.openFork("s-fork-\(destination.rawValue)", at: destination, beside: chat))

        let intent = try #require(store.pendingIntents.first)
        switch destination.opening {
        case .split:
            // Shown now, in its own split; the chat's pane lists only the chat.
            guard case .splitPane(let target, let direction, _, let provisional) = intent else {
                Issue.record("\(destination): not a split intent: \(intent)")
                return
            }
            #expect(target == PaneID(rawValue: 1))
            #expect(direction == (destination == .down ? .down : .right))
            #expect(provisional.tab?.kind == .conversation)
            #expect(store.pane(PaneID(rawValue: 1))?.tabs.map(\.surface) == [SurfaceID(rawValue: 1)])
            #expect(seen.held.isEmpty)
        case .tab:
            guard case .createTab(let target, _) = intent else {
                Issue.record("\(destination): not a tab intent: \(intent)")
                return
            }
            #expect(target == PaneID(rawValue: 1))
            #expect(seen.held.isEmpty, "a new tab shows in the chat's pane: nothing to hold out")
        case .moved:
            guard case .createTab(let target, _) = intent else {
                Issue.record("\(destination): not a tab intent: \(intent)")
                return
            }
            #expect(target == PaneID(rawValue: 1))
            // Held out of the chat's strip from the gesture, before the store answers.
            #expect(seen.held == [chat], "\(destination): the fork's tab shows in the chat's strip on its way")
        }
        if seen.creates.isEmpty { for await _ in seen.heard { break } }
        try #require(seen.creates.count == 1, "\(destination): one new-conversation-tab")
        #expect((seen.creates[0] != nil) == (destination.opening == .split))
    }
}
