import AppKit
import CmuxHomeCore
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabHome
import Testing

/// A queued agent's pill never does nothing on a click (user 2026-11-08, after the Home split pane went): a plain
/// click shows a small card over the pill with where it stands ("Starts next", "1 ahead of it") and Start now, and
/// the pill's context menu has Start now too. Home still never splits. Drives the real
/// `HomeNativeTranscriptView` over a `HomeStore` on the mock owner, in an offscreen window never ordered front.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeQueuedAgentPillTests {
    private struct Home {
        let window: NSWindow
        let store: HomeStore
        let view: HomeNativeTranscriptView
        let conversation: ConversationID
    }

    /// Home with one Chief run: a5 at work, then a6 and a7 queued behind the cap (a6 starts first).
    private func home() async throws -> Home {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source)
        store.start()
        let inbox = try await source.inbox()
        let chief = await source.chief.id
        let id = try #require((inbox.conversations.first { $0.participants.contains { $0.id == chief } } ?? inbox.conversations.first)?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(view)
        await view.binding.opened()
        let turn = IdempotencyKey("queued-run")
        _ = await source.post("I started three agents.", from: chief, in: id, key: turn)
        let start = Date(timeIntervalSince1970: 1_000)
        let messages = [("a5", false), ("a6", true), ("a7", true)].enumerated().map { index, agent in
            HomeAgentRun.Message(id: "m\(index)", sequence: UInt64(index + 1), revision: 1, peer: agent.0, outgoing: true,
                                 text: "Title: Task \(agent.0)\n\nDo it.", date: start.addingTimeInterval(Double(index)), queued: agent.1)
        }
        let run = HomeAgentRun(conversation: id, id: turn.rawValue, author: chief, turn: turn, answers: [], revision: 1, messages: messages)
        await source.streamLive(.run(HomeLiveRunChange(conversation: id, author: chief, run: turn.rawValue, turn: turn, status: "done", agentRun: run)))
        // The mock publishes on its own task: give it turns until the store has the run (no clock involved).
        for _ in 0..<100_000 where store.queuedAgents(in: id) != ["a6", "a7"] { await Task.yield() }
        try #require(store.queuedAgents(in: id) == ["a6", "a7"])
        view.layoutSubtreeIfNeeded()
        return Home(window: window, store: store, view: view, conversation: id)
    }

    private func close(_ home: Home) {
        home.view.stop()
        home.store.stop()
        home.window.close()
    }

    @Test func aClickOnAQueuedPillShowsWhereItStandsAndStartNow() async throws {
        let home = try await home()
        defer { close(home) }
        var started: [String] = []
        home.view.onStartAgent = { peer in started.append(peer); return true }
        let before = home.view.subviews.map(ObjectIdentifier.init)
        let click = try #require(home.view.transcript.onAgentPill)

        click("a7", NSRect(x: 40, y: 300, width: 200, height: 30))
        let card = try #require(home.view.agentCard, "a click on a queued pill did nothing")
        #expect(card.peer == "a7")
        #expect(card.title == "Task a7")
        #expect(card.status == "1 ahead of it")
        let button = try #require(card.startNowButton, "a queued agent's card has no Start now")
        // Home never splits for it: no column, the chat keeps its width.
        #expect(home.view.subviews.map(ObjectIdentifier.init) == before)
        #expect(home.view.transcript.frame.width == home.view.bounds.width)

        button.performClick(nil)
        await home.view.pendingAgentStart?.value
        #expect(started == ["a7"])

        click("a6", NSRect(x: 40, y: 260, width: 200, height: 30))
        #expect(home.view.agentCard?.status == "Starts next")
    }

    @Test func aWorkingPillWithNoWorkspaceSaysSoWithNoStartNow() async throws {
        let home = try await home()
        defer { close(home) }
        home.view.onStartAgent = { _ in true }
        let click = try #require(home.view.transcript.onAgentPill)
        click("a5", NSRect(x: 40, y: 220, width: 200, height: 30))
        let card = try #require(home.view.agentCard)
        #expect(card.status == "Working")
        #expect(card.startNowButton == nil)
    }

    /// The menu's Start now is the registry's `home.startQueuedAgent` row (check-menu-actions.py: no inline
    /// selector), so a click on it runs the action the palette and `cmux home start-agent` run, on this agent.
    @Test func aQueuedPillsContextMenuHasStartNow() async throws {
        let home = try await home()
        defer { close(home) }
        home.view.onStartAgent = { _ in true }
        let registry = ActionRegistry(catalog: ActionCatalog.all.filter { $0.id == "home.startQueuedAgent" })
        var started: [String] = []
        registry.bindEffect("home.startQueuedAgent", effect: { invocation in
            started.append(invocation["agent"]?.stringValue ?? "")
            return .done
        })
        let conversation = home.conversation.rawValue
        home.view.startAgentMenuItem = { peer in
            registry.makeContextMenuItem(for: "home.startQueuedAgent", in: .agentChat,
                                         arguments: ["agent": .string(peer), "conversation": .string(conversation)])
        }
        let menu = try #require(home.view.transcript.agentPillMenu)
        let items = menu("a7")
        let index = try #require(items.firstIndex { $0.title == "Start now" }, "no Start now in \(items.map(\.title))")
        #expect(items[index].identifier?.rawValue == "cmux.action.home.startQueuedAgent")
        #expect(menu("a5").contains { $0.title == "Start now" } == false)
        // The item runs as a click on it does: through the menu.
        let shown = NSMenu()
        items.forEach(shown.addItem)
        shown.performActionForItem(at: index)
        #expect(started == ["a7"])
    }

}
