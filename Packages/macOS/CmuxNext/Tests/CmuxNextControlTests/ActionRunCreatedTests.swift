@testable import CmuxNextControl
import Foundation
import CmuxNextCompat
import Testing

/// Creates a tab the way a loaded app can: the snapshot reaches the command's
/// daemon sequence first, and the tab shows up in a later publish (the store
/// builds it after the event that moved the sequence). With `appears` false
/// the tab never shows (closed again in the same run).
final class LaggingCreateExecutor: ControlActionExecutor {
    let router = Mutex<ControlRouter?>(nil)
    let appears: Bool

    init(appears: Bool = true) {
        self.appears = appears
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { performActionTracked(request).outcome }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        let router = router.withLock { $0 }
        let appears = appears
        Task { @MainActor in
            let scope = ControlCommandScope.current
            let ticket = scope?.begin()
            router?.snapshots.publish { $0.topology.daemonSequence = 9 }
            scope?.noteCreated([ControlCreatedObject(.tab, "21")])
            scope?.noteBarrier(9, machine: ControlCommandScope.localMachine)
            scope?.end(ticket, failure: nil)
            guard appears else { return }
            try? await Task.sleep(for: .milliseconds(200))
            router?.snapshots.publish { snapshot in
                let tab = ControlTabInfo(id: "tab-new", surface: "21", kind: "browser", title: "Example")
                snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
            }
        }
        return ControlActionRun(outcome: .ran)
    }
}

/// `action.run`'s `created` lists what the run made even when the snapshot
/// that reflects its sequence does not show it yet (`cmux tab new` under
/// load, plans/cmux-next/cli.md Remaining 13).
@Suite(.timeLimit(.minutes(1))) struct ActionRunCreatedTests {
    @Test func aCreatedTabTheSettledSnapshotLacksIsReportedOnceItAppears() async throws {
        let executor = LaggingCreateExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = BrowserOpenSplitTests.snapshot() }
        executor.router.withLock { $0 = router }
        let reply = try await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "openBrowser"])).get()
        #expect(reply["ran"] == true)
        #expect(reply["created"] == ["tab-new"], "\(reply)")
    }

    /// The wait takes at most half of what is left of the request's own
    /// deadline (2 s by default), so the reply has the rest to go out on a
    /// loaded machine (cx-6ynqg): a created tab that never shows is left out,
    /// and the run still reports it ran before the deadline. The run's own
    /// settling counts against that half, so a loaded host can answer past
    /// 1.5 s (1.66 s on the macOS 27 lane with the package running in
    /// parallel, cx-7l2nc); the contract is the deadline itself. Waiting the
    /// whole `createdLimit`, as before cx-6ynqg, answers after it.
    @Test func aCreatedTabThatNeverShowsStillAnswersRanBeforeTheDeadline() async throws {
        let executor = LaggingCreateExecutor(appears: false)
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        router.snapshots.publish { $0 = BrowserOpenSplitTests.snapshot() }
        executor.router.withLock { $0 = router }
        let started = ContinuousClock.now
        let reply = try await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "openBrowser"])).get()
        let took = ContinuousClock.now - started
        #expect(reply["ran"] == true)
        #expect(reply["created"] == [], "\(reply)")
        #expect(took < .seconds(2), "the reply took \(took), past its 2 s deadline")
    }
}
