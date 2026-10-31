@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A window's create lane (`WorkspaceLanes`, cx-7cit9) and Close Workspace with no target.
/// A create the store has caught up with must not stay outstanding: when its workspace was closed
/// another way (the sidebar's close button, which names its row, or the CLI) before any prune saw
/// it listed, the next Cmd-Shift-W took that stale create, closed the already-gone workspace and
/// returned, so the press did nothing.
@MainActor @Suite struct WorkspaceLanesTests {
    @MainActor private final class Closed {
        var keys: [String] = []
    }

    @MainActor private final class Flag {
        var on = false
    }

    /// Holds a create's body until the test lets it finish.
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        var isWaiting: Bool { continuation != nil }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private static func key(_ raw: String) -> WorkspaceKey { WorkspaceKey(rawValue: raw) }

    @Test func aSettledCreateClosedElsewhereIsNotTakenByALaterClose() async throws {
        let lanes = WorkspaceLanes()
        let closed = Closed()
        let applied = Flag()
        let id = try await lanes.create(Self.key("made"), window: "w", close: { closed.keys.append($0) },
                                        settle: { { applied.on } }) { "made" }
        #expect(id == "made")
        // The store applies the create (and, before any prune saw it listed, its close from the
        // sidebar row): the lane never hears of the close.
        applied.on = true
        // Cmd-Shift-W in that window closes the shown workspace, not the gone create.
        #expect(!lanes.closeNewestCreate(in: "w", listed: { _ in false }))
        #expect(lanes.outstandingCreates(in: "w") == 0)
        #expect(closed.keys.isEmpty)
    }

    @Test func aCreateTheStoreHasNotCaughtUpWithIsClosedByKey() async throws {
        let lanes = WorkspaceLanes()
        let closed = Closed()
        _ = try await lanes.create(Self.key("made"), window: "w", close: { closed.keys.append($0) }, settle: { { false } }) { "made" }
        // Made but not listed yet: the window still shows the previous workspace, so the press takes this one.
        #expect(lanes.closeNewestCreate(in: "w", listed: { _ in false }))
        while closed.keys.isEmpty { await Task.yield() }
        #expect(closed.keys == ["made"])
    }

    @Test func aCloseDuringTheCreateClosesItOnceMade() async throws {
        let lanes = WorkspaceLanes()
        let closed = Closed()
        let gate = Gate()
        let create = Task { @MainActor in
            try await lanes.create(Self.key("flight"), window: "w", close: { closed.keys.append($0) }, settle: { { false } }) {
                await gate.wait()
                return "flight"
            }
        }
        while !gate.isWaiting { await Task.yield() }
        #expect(lanes.closeNewestCreate(in: "w", listed: { _ in false }))
        // A second press finds nothing more to take from the lane.
        #expect(!lanes.closeNewestCreate(in: "w", listed: { _ in false }))
        gate.open()
        _ = try await create.value
        #expect(closed.keys == ["flight"])
        #expect(lanes.outstandingCreates(in: "w") == 0)
    }

    @Test func aCloseBeforeTheCreateStartsCancelsIt() async throws {
        let lanes = WorkspaceLanes()
        let gate = Gate()
        let first = Task { @MainActor in
            try await lanes.create(Self.key("first"), window: "w", close: { _ in }, settle: { { false } }) {
                await gate.wait()
                return "first"
            }
        }
        while !gate.isWaiting { await Task.yield() }
        let second = Task { @MainActor in
            try await lanes.create(Self.key("second"), window: "w", close: { _ in }, settle: { { false } }) { "second" }
        }
        while lanes.outstandingCreates(in: "w") < 2 { await Task.yield() }
        // The newest (not started) is taken: it never runs.
        #expect(lanes.closeNewestCreate(in: "w", listed: { _ in false }))
        gate.open()
        #expect(try await first.value == "first")
        await #expect(throws: CancellationError.self) { try await second.value }
        // The first is listed now: a press closes the shown workspace, and nothing is left in the lane.
        #expect(!lanes.closeNewestCreate(in: "w", listed: { $0 == "first" }))
        #expect(lanes.outstandingCreates(in: "w") == 0)
    }
}
