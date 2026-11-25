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
        var held: [PaneID] = []
        let (heard, hear) = AsyncStream<Void>.makeStream()
    }

    private static let host = "install:fork-placement-test"

    /// One chat tab alone on its screen; agent tab creates are faked (recorded, then refused).
    private static func chat(answering: Bool = false) throws -> (AppServices, AgentTabStore, String, Seen) {
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
        tabs.locateScoped = { [weak services] _ in services.map { (pane: PaneID(rawValue: 1), daemon: $0.daemon) } }
        tabs.rightColumnScoped = { _ in .init(sourceWidth: 1400) }
        tabs.seriallyScoped = { _, turn in turn({}); return true }
        tabs.openInMainPaneScoped = { _, _, _, _, _ in nil }
        let seen = Seen()
        tabs.holdOutbound = { pane, _ in
            seen.held.append(pane)
            return nil
        }
        tabs.create = { _, _, _, _, _, split in
            seen.creates.append(split)
            seen.hear.yield()
            guard answering else { throw CancellationError() }
            return (created: AgentTabCreated(key: "fork-tab", surface: SurfaceID(rawValue: 2)), sequence: nil)
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
            #expect(seen.held == [PaneID(rawValue: 1)], "\(destination): the fork's tab shows in the chat's strip on its way")
        }
        if seen.creates.isEmpty { for await _ in seen.heard { break } }
        try #require(seen.creates.count == 1, "\(destination): one new-conversation-tab")
        #expect((seen.creates[0] != nil) == (destination.opening == .split))
    }

    /// Review of #37709 at 203371f3: the store can list a New Window fork's new pane before Move Tab to New Window has
    /// placed its workspace in the new window (`placeMoved`), and a focus in that interval showed the fork's workspace
    /// in the chat's window. The fork takes the keyboard only once the move answered, with its window placed.
    @Test(.timeLimit(.minutes(1)), arguments: [AgentForkDestination.window, .workspace])
    func aForkToANewWindowFocusesOnlyOnceItsWindowIsPlaced(destination: AgentForkDestination) async throws {
        let (services, tabs, chat, _) = try Self.chat(answering: true)
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "tab.focus", title: "Focus", category: .other)])
        let focuses = Focuses()
        registry.bind("tab.focus", invoke: { _ in focuses.count += 1; focuses.hear.yield() })
        tabs.actionRegistry = registry
        let (moving, moveStarted) = AsyncStream<Bool>.makeStream()
        let gate = Gate()
        tabs.moveToNewWorkspace = { [weak services] _, _, newWindow in
            // The store lists the fork in its new pane now, outside the chat's pane; the move's reply, and the
            // window's placement after it, wait.
            tabs.locateScoped = { _ in services.map { (pane: PaneID(rawValue: 2), daemon: $0.daemon) } }
            moveStarted.yield(newWindow)
            return await withCheckedContinuation { gate.open = $0 }
        }

        #expect(tabs.openFork("s-fork-\(destination.rawValue)", at: destination, beside: chat))
        var moves = moving.makeAsyncIterator()
        #expect(await moves.next() == (destination == .window))
        for _ in 0..<50 { await Task.yield() }
        #expect(focuses.count == 0, "\(destination): the fork was focused before its workspace was placed")

        gate.open?.resume(returning: true)
        if focuses.count == 0 { for await _ in focuses.heard { break } }
        #expect(focuses.count == 1)
        withExtendedLifetime(registry) {}
    }

    /// Review of #37709 at f63b9573: with no hold (no window shows the chat's pane, as after a switch of workspace while the
    /// fork was pending), `hold?.finish(moved: await …)` skipped the await, and a Left or Above fork took the keyboard
    /// before its move landed. The fork waits for the store to list it outside the chat's pane, hold or not.
    @Test(.timeLimit(.minutes(1)), arguments: [AgentForkDestination.left, .up])
    func withNoHoldAMovedForkFocusesOnlyOnceItMoved(destination: AgentForkDestination) async throws {
        let (_, tabs, chat, _) = try Self.chat(answering: true)
        tabs.holdOutbound = { _, _ in nil }
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "tab.focus", title: "Focus", category: .other),
                                                ActionDescriptor(id: "tab.moveToNewSplit", title: "Move", category: .other)])
        let focuses = Focuses(), moves = Focuses()
        registry.bind("tab.focus", invoke: { _ in focuses.count += 1; focuses.hear.yield() })
        registry.bind("tab.moveToNewSplit", invoke: { _ in moves.count += 1; moves.hear.yield() })
        tabs.actionRegistry = registry

        #expect(tabs.openFork("s-fork-\(destination.rawValue)", at: destination, beside: chat))
        if moves.count == 0 { for await _ in moves.heard { break } }
        // The move is asked; the store still lists the fork in the chat's pane.
        for _ in 0..<50 { await Task.yield() }
        #expect(focuses.count == 0, "\(destination): the fork took the keyboard before its move landed")

        // The store never lists it elsewhere here (the faked move does nothing): the fork focuses once that wait is
        // over (TabMirror's bound), never before it.
        if focuses.count == 0 { for await _ in focuses.heard { break } }
        #expect(focuses.count == 1)
        withExtendedLifetime(registry) {}
    }

    @MainActor private final class Focuses {
        var count = 0
        let (heard, hear) = AsyncStream<Void>.makeStream()
    }

    @MainActor private final class Gate {
        var open: CheckedContinuation<Bool, Never>?
    }
}
