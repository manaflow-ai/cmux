@testable import CmuxNextControl
import Foundation
import Synchronization
import Testing

/// Creates a tab the way a loaded app can: the snapshot reaches the command's
/// daemon sequence first, and the tab shows up in a later publish (the store
/// builds it after the event that moved the sequence).
final class LaggingCreateExecutor: ControlActionExecutor {
    let router = Mutex<ControlRouter?>(nil)

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { performActionTracked(request).outcome }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        let router = router.withLock { $0 }
        Task { @MainActor in
            let scope = ControlCommandScope.current
            let ticket = scope?.begin()
            router?.snapshots.publish { $0.topology.daemonSequence = 9 }
            scope?.noteCreated([ControlCreatedObject(.tab, "21")])
            scope?.noteBarrier(9, machine: ControlCommandScope.localMachine)
            scope?.end(ticket, failure: nil)
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
}
