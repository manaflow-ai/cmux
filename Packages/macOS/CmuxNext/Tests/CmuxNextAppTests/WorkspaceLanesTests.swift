@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A window's create lane (`WorkspaceLanes`, cx-7cit9) and Close Workspace with no target.
/// A finished create must not stay outstanding: when its workspace was later closed another way
/// (the sidebar's close button, which names its row, or the CLI), the next Cmd-Shift-W took that
/// stale create, closed the already-gone workspace and returned, so the press did nothing.
@MainActor @Suite struct WorkspaceLanesTests {
    @MainActor private final class Closed {
        var keys: [String] = []
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

    @Test func aFinishedCreateIsNotTakenByALaterClose() async throws {
        let lanes = WorkspaceLanes()
        let closed = Closed()
        let id = try await lanes.create(Self.key("made"), window: "w", close: { closed.keys.append($0) }) { "made" }
        #expect(id == "made")
        // The workspace is closed from its sidebar row: the lane never hears of it.
        #expect(lanes.outstandingCreates(in: "w") == 0)
        // Cmd-Shift-W in that window closes the shown workspace, not the gone create.
        #expect(!lanes.closeNewestCreate(in: "w"))
        #expect(closed.keys.isEmpty)
    }

    @Test func aCloseDuringTheCreateClosesItOnceMade() async throws {
        let lanes = WorkspaceLanes()
        let closed = Closed()
        let gate = Gate()
        let create = Task { @MainActor in
            try await lanes.create(Self.key("flight"), window: "w", close: { closed.keys.append($0) }) {
                await gate.wait()
                return "flight"
            }
        }
        while !gate.isWaiting { await Task.yield() }
        #expect(lanes.closeNewestCreate(in: "w"))
        // A second press finds nothing more to take from the lane.
        #expect(!lanes.closeNewestCreate(in: "w"))
        gate.open()
        _ = try await create.value
        #expect(closed.keys == ["flight"])
        #expect(lanes.outstandingCreates(in: "w") == 0)
    }

    @Test func aCloseBeforeTheCreateStartsCancelsIt() async throws {
        let lanes = WorkspaceLanes()
        let gate = Gate()
        let first = Task { @MainActor in
            try await lanes.create(Self.key("first"), window: "w", close: { _ in }) {
                await gate.wait()
                return "first"
            }
        }
        while !gate.isWaiting { await Task.yield() }
        let second = Task { @MainActor in
            try await lanes.create(Self.key("second"), window: "w", close: { _ in }) { "second" }
        }
        while lanes.outstandingCreates(in: "w") < 2 { await Task.yield() }
        // The newest (not started) is taken: it never runs.
        #expect(lanes.closeNewestCreate(in: "w"))
        gate.open()
        #expect(try await first.value == "first")
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(lanes.outstandingCreates(in: "w") == 0)
    }
}
