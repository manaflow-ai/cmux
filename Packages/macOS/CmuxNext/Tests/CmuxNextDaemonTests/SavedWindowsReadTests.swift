import CmuxNextDaemon
import Foundation
import Testing

/// #26681: the launch's read of the saved window records (`SavedWindowsRead`). A daemon still
/// starting answered it after the 2 s control-plane deadline, and the failure read as "nothing
/// saved", so the relaunch lost every window but one. The read waits past that deadline, tries
/// again after a timeout, and reports an unanswered read as unread, never as empty.
@MainActor @Suite
struct SavedWindowsReadTests {
    static let twoWindows = WindowStateDocument(windows: [
        WindowRecord(id: "front", workspaceKey: WorkspaceKey(rawValue: "ws-a"), workspaceKeys: [WorkspaceKey(rawValue: "ws-a")]),
        WindowRecord(id: "second", workspaceKey: WorkspaceKey(rawValue: "ws-b"), workspaceKeys: [WorkspaceKey(rawValue: "ws-b")]),
    ])

    final class Attempts {
        var deadlines: [Duration] = []
    }

    @Test func aReadThatTimesOutOnceStillRestoresEveryWindow() async throws {
        let attempts = Attempts()
        let outcome = await SavedWindowsRead().run { deadline in
            attempts.deadlines.append(deadline)
            if attempts.deadlines.count == 1 { throw DaemonError.timedOut("frontend_projection.get") }
            return Self.twoWindows
        }
        guard case .loaded(let document) = outcome else { Issue.record("the read gave up: \(outcome)"); return }
        #expect(document.windows.map(\.id) == ["front", "second"])
        #expect(attempts.deadlines == [.seconds(10), .seconds(10)], "each attempt waits past the 2 s control-plane deadline")
    }

    @Test func aReadThatNeverAnswersIsUnreadNotEmpty() async {
        let attempts = Attempts()
        let outcome = await SavedWindowsRead(attempts: 3).run { deadline in
            attempts.deadlines.append(deadline)
            throw DaemonError.timedOut("frontend_projection.get")
        }
        guard case .unread = outcome else { Issue.record("an unanswered read must not read as nothing saved"); return }
        #expect(attempts.deadlines.count == 3)
    }

    @Test func aDaemonThatOutlastsThreeDeadlinesStillRestoresEveryWindow() async {
        let attempts = Attempts()
        let outcome = await SavedWindowsRead().run { deadline in
            attempts.deadlines.append(deadline)
            if attempts.deadlines.count <= 4 { throw DaemonError.timedOut("frontend_projection.get") }
            return Self.twoWindows
        }
        guard case .loaded(let document) = outcome else { Issue.record("restoration stopped before the daemon recovered"); return }
        #expect(document.windows.map(\.id) == ["front", "second"])
        #expect(attempts.deadlines.count == 5)
    }

    @Test func aConnectionThatIsNotReadyIsNotRetriedAtOnce() async {
        let attempts = Attempts()
        let outcome = await SavedWindowsRead().run { deadline in
            attempts.deadlines.append(deadline)
            throw DaemonError.notConnected
        }
        guard case .unread = outcome else { Issue.record("expected unread"); return }
        #expect(attempts.deadlines.count == 1)
    }

    @Test func aDisconnectedReadWaitsForTheCurrentConnectionBeforeRetrying() async {
        let attempts = Attempts()
        var readinessWaits = 0
        let outcome = await SavedWindowsRead().run(waitUntilReady: { readinessWaits += 1 }) { deadline in
            attempts.deadlines.append(deadline)
            switch attempts.deadlines.count {
            case 1: throw DaemonError.notConnected
            case 2: throw DaemonError.connectionClosed(reason: "daemon restarting")
            case 3: throw DaemonError.daemonShutdown
            default: return Self.twoWindows
            }
        }
        guard case .loaded(let document) = outcome else { Issue.record("reconnect did not resume restoration"); return }
        #expect(document.windows.map(\.id) == ["front", "second"])
        #expect(readinessWaits == 4)
    }

    @Test func quittingCancelsThePendingReadInsteadOfRetrying() async {
        let read = Task { @MainActor in
            await SavedWindowsRead().run { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw DaemonError.timedOut("frontend_projection.get")
            }
        }
        guard case .unread(let error) = await read.value else { Issue.record("a cancelled restore completed"); return }
        #expect(error is CancellationError)
    }
}
