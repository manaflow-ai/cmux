@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// A sidebar pass only posts the snapshot: it is built in an idle task, from
/// what the sidebar shows then, one per burst of passes, and the checks run again when it does.
@MainActor struct SidebarSnapshotRecorderTests {
    final class Harness {
        var incognito: Set<String> = []
        var savable = true
        private(set) var saved: [(window: String, sequence: UInt64, active: String?)] = []
        private(set) var posts: [(owner: String, maxDelay: Duration, body: @MainActor () -> Void)] = []

        var target: SidebarSnapshotRecorder.Target {
            SidebarSnapshotRecorder.Target(isIncognito: { [unowned self] in self.incognito.contains($0) },
                                           isSavable: { [unowned self] _ in self.savable },
                                           save: { [unowned self] snapshot, window, sequence in
                                               self.saved.append((window, sequence, snapshot.activeProfileID))
                                           },
                                           postIdle: { [unowned self] owner, maxDelay, body in self.posts.append((owner, maxDelay, body)) })
        }

        /// One idle period: runs the tasks posted before it.
        func runIdle() {
            let due = posts
            posts = []
            for post in due {
                post.body()
            }
        }
    }

    let harness = Harness()
    let recorder = SidebarSnapshotRecorder()
    let model = SidebarModel()

    @Test func aBurstOfPassesBuildsOneSnapshotInAnIdleTask() {
        for name in ["a", "b", "c"] {
            model.activeProfileID = ProfileKey(name)
            recorder.record(model, window: "w1", target: harness.target)
        }
        #expect(harness.saved.isEmpty, "no snapshot is built in a pass")
        #expect(harness.posts.count == 1, "one idle task serves the burst")
        #expect(harness.posts.first?.owner == "SidebarSnapshot.record")
        #expect(harness.posts.first?.maxDelay == .milliseconds(2500))

        harness.runIdle()
        #expect(harness.saved.count == 1)
        #expect(harness.saved.first?.sequence == 1)
        #expect(harness.saved.first?.active == ProfileKey("c").rawValue, "the newest state, read when the task runs")

        recorder.record(model, window: "w1", target: harness.target)
        #expect(harness.posts.isEmpty, "nothing changed since the save")

        model.activeProfileID = ProfileKey("d")
        recorder.record(model, window: "w1", target: harness.target)
        harness.runIdle()
        #expect(harness.saved.map(\.sequence) == [1, 2])
    }

    /// The window closed (or the launch is not over) between the pass and the idle task: nothing is
    /// saved, and the next pass posts again once it may.
    @Test func aWindowThatStopsBeingSavableBeforeTheTaskIsNotSaved() {
        model.activeProfileID = ProfileKey("a")
        recorder.record(model, window: "w1", target: harness.target)
        harness.savable = false
        harness.runIdle()
        #expect(harness.saved.isEmpty)
        recorder.record(model, window: "w1", target: harness.target)
        #expect(harness.posts.isEmpty, "not savable: no task")

        harness.savable = true
        recorder.record(model, window: "w1", target: harness.target)
        harness.runIdle()
        #expect(harness.saved.count == 1)
    }

    /// A window that went incognito before its task ran is never saved, even after it leaves the
    /// incognito set on its way out.
    @Test func anIncognitoWindowIsNeverSaved() {
        model.activeProfileID = ProfileKey("a")
        recorder.record(model, window: "w1", target: harness.target)
        harness.incognito = ["w1"]
        harness.runIdle()
        harness.incognito = []
        model.activeProfileID = ProfileKey("b")
        recorder.record(model, window: "w1", target: harness.target)
        harness.runIdle()
        #expect(harness.saved.isEmpty)
        #expect(harness.posts.isEmpty)
    }

    /// Quit: a change whose idle task has not run is built at once and reaches the store before its
    /// flush, with the newest sequence; the queued task then saves nothing.
    @Test func flushNowSavesTheQueuedChangeWithNoIdleRun() async {
        let store = SidebarSnapshotStore(file: nil)
        model.activeProfileID = ProfileKey("a")
        recorder.record(model, window: "w1", target: harness.target)
        harness.runIdle()
        guard let first = harness.saved.first else {
            Issue.record("the first change was not saved")
            return
        }
        await store.record(SidebarSnapshot(sections: [SidebarSnapshot.Section](), profiles: [SidebarSnapshot.Profile](), activeProfileID: first.active), window: "w1", sequence: first.sequence)

        model.activeProfileID = ProfileKey("b")
        recorder.record(model, window: "w1", target: harness.target)
        #expect(harness.posts.count == 1, "queued, not run")
        guard let pending = recorder.flushNow(model, window: "w1", target: harness.target) else {
            Issue.record("flushNow built nothing for a queued change")
            return
        }
        #expect(pending.sequence == 2)
        await store.record(pending.snapshot, window: "w1", sequence: pending.sequence)
        await store.flush()
        #expect(await store.document.snapshot(for: "w1", fallback: false)?.activeProfileID == ProfileKey("b").rawValue)

        harness.runIdle()
        #expect(harness.saved.count == 1, "the queued task found the change saved")
        #expect(recorder.flushNow(model, window: "w1", target: harness.target) == nil, "nothing waits any more")

        model.activeProfileID = ProfileKey("c")
        recorder.record(model, window: "w1", target: harness.target)
        #expect(harness.posts.count == 1, "the next change posts again after a flush")
    }
}
