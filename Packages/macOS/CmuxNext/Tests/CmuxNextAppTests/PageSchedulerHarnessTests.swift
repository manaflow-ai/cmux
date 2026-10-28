import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesignTokens
import CmuxNextPages
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The p06-scheduler rule 9 harness for the owners task 309 moved (CmuxNextApp/{Pages, InternalPages,
/// NewTab, Viewers}): a page host's reply waits on its hidden tab's queue and runs once on show, and goes
/// with a closed tab; a store with no window still closes a gone pane's page tabs, one frame later and never
/// inside the open; the update surface sends its first value in its posted task; the page retirer and the
/// file change watch run on their deadlines; a quit flush stops waiting for a dead page at its deadline.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct PageSchedulerHarnessTests {
    // MARK: Page host replies (PageTabReplies)

    @Test func aHiddenTabsReplyWaitsForItsShowAndAppliesOnce() async {
        let work = linklessMainWork()
        let node = VisibilityNode(root: "test.tab", own: .hidden)
        let replies = PageTabReplies(owner: "test.page-reply", on: work) { _ in node }
        let applied = ReplyLog()
        let reply = replies.reply(for: "tab") { 7 } apply: { applied.values.append($0) }
        await reply.value
        #expect(runMainLoop { replies.pendingCount(for: "tab") == 1 }, "the reply did not reach the tab's queue")
        Self.spin()
        #expect(applied.values.isEmpty, "a hidden tab's reply applied")
        node.set(.visible)
        #expect(runMainLoop { applied.values == [7] }, "the shown tab's reply did not apply")
        Self.spin()
        #expect(applied.values == [7], "the reply applied more than once")
    }

    @Test func aClosedTabsReplyIsDropped() async {
        let work = linklessMainWork()
        let node = VisibilityNode(root: "test.tab", own: .hidden)
        let replies = PageTabReplies(owner: "test.page-reply", on: work) { _ in node }
        let applied = ReplyLog()
        let reply = replies.reply(for: "tab") { 1 } apply: { applied.values.append($0) }
        await reply.value
        #expect(runMainLoop { replies.pendingCount(for: "tab") == 1 })
        replies.close("tab")
        node.set(.visible)
        Self.spin()
        #expect(applied.values.isEmpty, "a closed tab's reply applied")
    }

    @Test func aReplyWithNoTabRunsAsOnePostedTask() async {
        let work = linklessMainWork()
        let replies = PageTabReplies(owner: "test.page-reply", on: work) { _ in nil }
        let applied = ReplyLog()
        let reply = replies.reply(for: nil) { 3 } apply: { applied.values.append($0) }
        await reply.value
        #expect(runMainLoop { applied.values == [3] })
        // An operation that runs until it is cancelled.
        let (never, keep) = AsyncStream<Void>.makeStream()
        defer { keep.finish() }
        let cancelled = replies.reply(for: nil) {
            for await _ in never {}
            return 4
        } apply: { applied.values.append($0) }
        cancelled.cancel()
        await cancelled.value
        Self.spin()
        #expect(applied.values == [3], "a cancelled reply applied")
    }

    // MARK: InternalPageTabStore's store follower

    /// The follower writes the model (tabs close), so it runs with no window showing the store; the close is its
    /// flush one frame later, never inside the store's change or the open that started the watch.
    @Test func aWindowlessStoresGonePaneTabsCloseOneFrameLater() throws {
        let rig = PageFrameRig()
        let store = Self.store()
        let kept = try #require(store.pane(1)?.id)
        let gone = try #require(store.pane(2)?.id)
        let pages = InternalPageTabStore(mainWork: rig.work)
        pages.open(.settings, in: kept, of: store)
        pages.open(.changelog, in: gone, of: store)
        rig.frame()
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneClosed(PaneDelta(
            workspace: 1, screen: 1, pane: 2, index: nil, entity: PaneSnapshot(id: 2, tabs: []), clientTransactionID: nil)))])
        #expect(pages.tabIDs(in: gone).count == 1, "the tab closed inside the store's change")
        rig.frame()
        #expect(pages.tabIDs(in: gone).isEmpty, "the gone pane's page tab stayed")
        #expect(pages.tabIDs(in: kept).count == 1, "the live pane's page tab closed")
    }

    @Test func aPaneAlreadyGoneAtTheOpenClosesInThePostedCheck() throws {
        let rig = PageFrameRig()
        let store = Self.store()
        let gone = try #require(store.pane(2)?.id)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneClosed(PaneDelta(
            workspace: 1, screen: 1, pane: 2, index: nil, entity: PaneSnapshot(id: 2, tabs: []), clientTransactionID: nil)))])
        let pages = InternalPageTabStore(mainWork: rig.work)
        pages.open(.changelog, in: gone, of: store)
        #expect(pages.tabIDs(in: gone).count == 1, "the open closed its own tab")
        rig.frame()
        #expect(pages.tabIDs(in: gone).isEmpty, "the posted check left a gone pane's tab")
    }

    // MARK: Update surface stream

    @Test func theUpdateSurfaceSendsItsFirstValueInThePostedTask() async throws {
        let rig = PageFrameRig()
        let provider = UpdateSurfaceProvider(kind: .updated, services: nil, mainWork: rig.work)
        let received = StreamEvents()
        let changes = try await provider.subscribe("cmux.changelog.surface.changes", filter: [:], context: PageCallContext(page: "cmux.test"),
                                                   onEvent: { received.events.append($0) })
        defer { changes.cancel() }
        #expect(received.events.isEmpty, "the first value was sent inside the subscribe")
        rig.frame()
        #expect(received.events == [.null], "the posted task sends the highlights once")
        rig.frame()
        #expect(received.events == [.null], "no change, no event")
    }

    // MARK: Deadlines

    @Test func thePageRetirerTearsDownAt500Milliseconds() {
        let rig = MainDeadlineRig()
        let retirer = PageRetirer(deadlines: rig.deadlines)
        var closed = 0
        retirer.retire(NSView()) { closed += 1 }
        #expect(retirer.count == 1 && closed == 0, "the teardown ran in the close's turn")
        rig.fireAndRun()
        #expect(retirer.count == 0 && closed == 1, "the teardown did not run at its deadline")
        #expect(rig.elapsed >= 0.5 && rig.elapsed < 0.55, "the teardown ran at \(rig.elapsed) s, not 500 ms")
    }

    @Test func aBurstOfFileEventsReadsOnceAfterTheDebounce() throws {
        let rig = MainDeadlineRig()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-change-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "notes.md")
        try Data("# One\n".utf8).write(to: file)
        var changes: [FileSnapshot?] = []
        let watch = FileChangeWatch(url: file, inWorkspace: { true }, deadlines: rig.deadlines, work: BackgroundWork(label: "test.change-watch")) {
            changes.append($0)
        }
        watch.noteEvent()
        rig.advance(by: .milliseconds(50))
        watch.noteEvent()
        #expect(watch.isSettling)
        rig.fireAndRun()
        #expect(rig.elapsed >= 0.15 && rig.elapsed < 0.2, "the debounce fired at \(rig.elapsed) s, not 100 ms after the last event")
        #expect(!watch.isSettling)
        #expect(runMainLoop { rig.deadlines.work.postedCount(.visible) == 1 }, "the read's reply did not reach main")
        #expect(changes.isEmpty, "the reply applied before its frame")
        rig.fireAndRun()
        #expect(changes.compactMap { $0 }.count == 1, "two events, one read of the file")
        watch.stop()
    }

    @Test func aQuitFlushStopsWaitingForADeadPageAtItsDeadline() async throws {
        let clock = ManualClock()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-quit-flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "notes.md")
        try Data("# Saved\n".utf8).write(to: file)
        let drafts = RecoveryDraftStore(directory: directory.appending(path: "drafts"),
                                        deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())), work: BackgroundWork(label: "test.recovery-drafts"))
        let document = FileQuitDocument(url: file, drafts: drafts, writable: { true }, clock: clock)
        document.edited(text: "# Unsaved\n", baseHash: FileDocument.hash(Data("# Saved\n".utf8)))
        #expect(document.hasUnsavedChanges)
        let (silence, held) = AsyncStream<Void>.makeStream()
        _ = document.addFlusher {
            for await _ in silence {}  // a crashed page never answers
            return true
        }
        let flush = Task { try await document.flushForQuit() }
        try await clock.waitForSleeper()
        clock.advance(by: FileQuitDocument.pageFlushTimeout)
        try await flush.value
        #expect(!document.hasUnsavedChanges, "the host did not write the last text after the deadline")
        #expect((try? String(contentsOf: file, encoding: .utf8)) == "# Unsaved\n")
        held.finish()
        await document.settled()
    }

    // MARK: Helpers

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let panes = [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1)]), PaneSnapshot(id: 2, tabs: [])]
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: panes)
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    /// A few main run loop turns, for a test that checks nothing more happens.
    private static func spin() {
        for _ in 0..<10 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }
}

@MainActor
private final class ReplyLog {
    var values: [Int] = []
}
