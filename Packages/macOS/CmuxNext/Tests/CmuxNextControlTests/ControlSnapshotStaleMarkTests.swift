import CmuxNextCompat
@testable import CmuxNextControl
import Testing

/// The control snapshot's stale mark (`ControlSnapshotStore.markStale()`, set after each control work-queue frame)
/// says main-actor state changed since the last build. Only a build of that state may clear it: a partial publish
/// that writes no main-actor topology (the context mask the registry bridge publishes after each focus change, the
/// action catalog, a settings write) must leave it, so the next read still builds and sees the frame's write
/// (read-your-writes). A CLI `pane.focus` then a read must answer the new focus.
@Suite struct ControlSnapshotStaleMarkTests {
    /// The main-actor state the App's publisher would build from: the focused pane, and the builds so far.
    private final class Model: Sendable {
        let pane = Mutex("before")
        let builds = Mutex(0)
    }

    /// A router, and a task that builds and publishes `model`'s focus whenever a reader starts waiting on a stale
    /// store (`waiterAdditions`), as the App's publisher does. Cancel the task at the end.
    private func router(_ model: Model) -> (ControlRouter, Task<Void, Never>) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let store = router.snapshots
        store.publish { $0.topology.focus = ControlFocus(paneID: "before") }
        let additions = store.waiterAdditions()
        let builder = Task {
            for await _ in additions where store.isStale {
                model.builds.withLock { $0 += 1 }
                let focused = model.pane.withLock { $0 }
                store.publish(coversMainActorState: true) { $0.topology.focus = ControlFocus(paneID: focused) }
            }
        }
        return (router, builder)
    }

    @Test(arguments: ["contextMask", "catalog", "settings"])
    func aPartialPublishAfterAWorkQueueFrameLeavesTheSnapshotStale(_ writer: String) async {
        let model = Model()
        let (router, builder) = router(model)
        defer { builder.cancel() }
        // A work-queue frame moved focus (the publisher's after-frame hook marks the snapshot stale).
        model.pane.withLock { $0 = "after" }
        router.snapshots.markStale()
        // Then a writer that does not build the topology publishes.
        switch writer {
        case "contextMask": router.updateContextMask(0b101)
        case "catalog": router.updateCatalog(ControlCatalog(actions: [], debugActionsAvailable: false))
        default: router.snapshots.publish { $0.settings = nil }
        }
        #expect(router.snapshots.isStale, "a \(writer) publish cleared the stale mark of a frame it did not build")
        let snapshot = await router.snapshots.fresh(deadline: .now + .seconds(10))
        #expect(model.builds.withLock { $0 } == 1, "the read after the \(writer) publish built nothing")
        #expect(snapshot?.topology.focus.paneID == "after", "the read answered the focus from before the frame")
        #expect(!router.snapshots.isStale, "the build that covers the frame left the snapshot stale")
        _ = await router.snapshots.fresh(deadline: .now + .seconds(10))
        #expect(model.builds.withLock { $0 } == 1, "a second read with nothing changed built again")
    }
}
