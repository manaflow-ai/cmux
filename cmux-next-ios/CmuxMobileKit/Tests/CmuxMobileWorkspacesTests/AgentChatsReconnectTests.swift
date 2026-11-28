import CmuxMobileModel
import Foundation
import Testing
#if os(iOS)
@testable import CmuxMobileWorkspaces

/// Leo 2026-11-21: "i keep seeing "the mac didnt answer in time" i dont want to see that + just
/// fix the connection to be smoother better faster visually too". The Chats list rides out a
/// connection that drops or goes quiet: no alert and no failure page, its rows kept, nothing
/// shown for a blip under the shared notice bound (10 s), then "Reconnecting to your Mac…",
/// past ``ConnectionPatience/giveUpAfter`` "Showing chats from earlier" (or, with nothing to
/// show, the failure that says what to do), and it asks again on its own until the Mac answers.
@MainActor
struct AgentChatsReconnectTests {
    static func chat(_ id: String) -> AgentChatListing {
        AgentChatListing(id: id, title: id, harness: "claude", cwd: "/p", status: "idle", updatedAt: nil, archived: false)
    }

    /// The Mac is unreachable while `down`; otherwise answers `page`.
    final class FlakyBackend: AgentChatsBackend {
        var down = true
        var asked = 0
        var page = AgentChatPage(chats: [], nextCursor: nil)
        func canListAgentChats(on macID: String) -> Bool { true }
        func agentChats(on macID: String, cursor: String?) async throws -> AgentChatPage {
            asked += 1
            if down { throw ConnectionInterrupted() }
            return page
        }
        func openAgentChat(_ chat: AgentChatListing, in workspace: Workspace) async throws -> WorkspaceTab { throw WorkspaceCreationError("no") }
        func openAgentChatInNewWorkspace(_ chat: AgentChatListing, on macID: String) async throws -> Workspace { throw WorkspaceCreationError("no") }
        func setAgentChatArchived(_ chat: AgentChatListing, archived: Bool, on macID: String) async throws -> AgentChatListing { chat }
        func openChatFolderInTerminal(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab { throw WorkspaceCreationError("no") }
        func stopAgentChat(_ chat: AgentChatListing, on macID: String) async throws {}
    }

    /// The model's clock and its waits between retries, driven by the test: time moves only when
    /// `advance` says, and a retry runs only when `retry` lets its wait end.
    final class Time: @unchecked Sendable {
        let start = ContinuousClock.now
        private let lock = NSLock()
        private var offset: Duration = .zero
        private var waiting: CheckedContinuation<Void, any Error>?
        private(set) var delays: [Duration] = []

        var now: ContinuousClock.Instant { lock.withLock { start + offset } }
        func advance(to elapsed: Duration) { lock.withLock { offset = elapsed } }
        var isWaiting: Bool { lock.withLock { waiting != nil } }

        func pause(_ delay: Duration) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // A wait the model replaced (a pull cancels its scheduled retry) ends as cancelled.
                let replaced = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                    defer { delays.append(delay); waiting = continuation }
                    return waiting
                }
                replaced?.resume(throwing: CancellationError())
            }
        }

        /// Ends the scheduled wait: the model asks the Mac again.
        func retry() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }
    }

    func model(_ backend: FlakyBackend, _ time: Time, memory: AgentChatsMemory = AgentChatsMemory()) -> AgentChatsModel {
        let model = AgentChatsModel(macID: "mac-1", backend: backend, memory: memory)
        model.now = { time.now }
        model.pause = { try await time.pause($0) }
        return model
    }

    /// Lets the model's retry run on its next main-actor turns (bounded).
    func settle(until done: () -> Bool) async {
        for _ in 0..<2000 where !done() { await Task.yield() }
    }

    /// A retry: the wait ends, the model asks again, and either schedules its next wait or stops.
    func retry(_ backend: FlakyBackend, _ time: Time) async {
        let asked = backend.asked
        time.retry()
        await settle { backend.asked > asked && (time.isWaiting || !backend.down) }
        await settle { false }
    }

    /// An empty list: a quiet loading state for a blip, "Connecting to your Mac…" once it lasts,
    /// and only past the bound the failure that says what to do. Never an alert.
    @Test func anEmptyListWaitsQuietlyThenSaysWhatToDo() async {
        let backend = FlakyBackend()
        let time = Time()
        let model = model(backend, time)
        await model.load()
        await settle { time.isWaiting }
        #expect(model.phase == .loading)
        #expect(!model.reconnecting, "a blip under 10 s shows nothing new")
        #expect(model.failure == nil)
        #expect(time.isWaiting)
        #expect(time.delays == [.milliseconds(500)])

        time.advance(to: .seconds(12))
        await retry(backend, time)
        #expect(model.phase == .loading)
        #expect(model.reconnecting, "past the notice bound: Connecting to your Mac…")
        #expect(!model.stale)
        #expect(time.delays == [.milliseconds(500), .seconds(1)], "backs off")

        time.advance(to: .seconds(50))
        await retry(backend, time)
        #expect(model.phase == .failed(ConnectionInterrupted.message))
        #expect(!model.reconnecting)
        #expect(model.failure == nil)
    }

    /// The screen's own retry of a failed empty list (AutoRetry, no Try Again) keeps the failure
    /// on screen while it asks (no blink back to the spinner), keeps the patience (a Mac still
    /// unreachable stays failed), and shows the chats once the Mac answers.
    @Test func theScreensOwnRetryKeepsTheFailureUntilTheMacAnswers() async {
        let backend = FlakyBackend()
        let time = Time()
        let model = model(backend, time)
        await model.load()
        await settle { time.isWaiting }
        time.advance(to: .seconds(50))
        await retry(backend, time)
        #expect(model.phase == .failed(ConnectionInterrupted.message))

        let asked = backend.asked
        await model.retryFailedLoad()
        #expect(backend.asked == asked + 1)
        #expect(model.phase == .failed(ConnectionInterrupted.message), "still past the bound: still failed, never loading")

        backend.down = false
        backend.page = AgentChatPage(chats: [Self.chat("a")], nextCursor: nil)
        await model.retryFailedLoad()
        #expect(model.phase == .loaded)
        #expect(model.chats.map(\.id) == ["a"])
    }

    /// Rows already listed stay on screen the whole time: reconnecting after 10 s, "from
    /// earlier" past the bound, and the fresh page as soon as the Mac answers again.
    @Test func listedRowsStayWhileItReconnectsAndRefreshWhenTheMacIsBack() async {
        let memory = AgentChatsMemory()
        memory.keep(AgentChatPage(chats: [Self.chat("a"), Self.chat("b")], nextCursor: nil), for: "mac-1")
        let backend = FlakyBackend()
        let time = Time()
        let model = model(backend, time, memory: memory)
        await model.load()
        await settle { time.isWaiting }
        #expect(model.phase == .loaded)
        #expect(model.chats.map(\.id) == ["a", "b"])
        #expect(!model.reconnecting)
        #expect(model.failure == nil)

        time.advance(to: .seconds(12))
        await retry(backend, time)
        #expect(model.reconnecting)
        #expect(!model.stale)
        #expect(model.chats.map(\.id) == ["a", "b"])

        time.advance(to: .seconds(50))
        await retry(backend, time)
        #expect(model.phase == .loaded)
        #expect(model.stale, "past the bound: Showing chats from earlier")
        #expect(model.reconnecting)
        #expect(model.chats.map(\.id) == ["a", "b"])
        #expect(time.isWaiting, "keeps asking past the bound while it has rows to show")

        backend.down = false
        backend.page = AgentChatPage(chats: [Self.chat("new"), Self.chat("a")], nextCursor: nil)
        await retry(backend, time)
        await settle { !model.reconnecting }
        #expect(!model.reconnecting)
        #expect(!model.stale)
        #expect(model.chats.map(\.id) == ["new", "a"])
        #expect(!time.isWaiting)
    }

    /// The person pulling to refresh starts the patience over.
    @Test func aPullStartsThePatienceOver() async {
        let backend = FlakyBackend()
        let time = Time()
        let model = model(backend, time)
        await model.load()
        await settle { time.isWaiting }
        time.advance(to: .seconds(12))
        await retry(backend, time)
        #expect(model.reconnecting)

        let waits = time.delays.count
        await model.load(pulled: true)
        await settle { time.delays.count > waits }
        #expect(!model.reconnecting, "a fresh start: quiet again for the notice bound")
        #expect(time.delays.last == .milliseconds(500))
    }
}
#endif
