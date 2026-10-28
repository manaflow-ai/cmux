import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextUpdater
import CmuxUpdater
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextUpdater, WebUpdates, Settings and DesignTokens sweep (plans/cmux-next/chrome-parity/p06-scheduler.md):
/// one case per migrated owner class. Update checks wake on the app's hidden wakes; the
/// install click's deadline, which a person waits on, never does; a feed read's result lands as one visible task in
/// its frame; the updater's card deadlines are classed `MainDeadline`s; a recovery draft's debounce is a background
/// deadline; the WebKit probe's answer and timeout are background tasks.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct UpdaterSchedulerSweepTests {
    typealias Base = UpdateStagedYieldsToNewerTests

    static func updater(_ rig: MainDeadlineRig, identity: UpdateBuildIdentity = TipUpdateCheckTests.tip, checkNode: VisibilityNode? = nil,
                        feed: Base.CountingFeed = Base.CountingFeed(xml: TipUpdateCheckTests.feed)) -> UpdaterService {
        let defaults = UserDefaults(suiteName: "UpdaterSchedulerSweepTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     prober: UpdateProber(fetcher: feed, architecture: .arm64), defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, now: { Base.now },
                                     work: BackgroundWork(label: "test.updater-sweep"), deadlines: rig.deadlines, checkNode: checkNode)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        updater.tipCheck.downloadsInBackground = { true }
        updater.stagedRefresh.replaceable = { true }
        return updater
    }

    static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    // MARK: MainDeadline whenHidden (the feed checks)

    @Test func theTipChecksWakeAlignsToTheHiddenAppsWakes() {
        let rig = MainDeadlineRig(), app = VisibilityNode(root: "app", own: .hidden)
        let updater = Self.updater(rig, checkNode: app)
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: true, ring: "nightly")
        updater.start()
        #expect(updater.tipCheck.timer.workClass == .background)
        #expect(updater.tipCheck.timer.plannedWake?.rule == .hidden, "a hidden app's tip check is not hidden-aligned")
        app.set(.visible)
        #expect(updater.tipCheck.timer.plannedWake?.rule == .flexible, "a shown app's tip check stayed hidden-aligned")
    }

    @Test func theStagedProbeAlignsButTheInstallClicksDeadlineNever() {
        let rig = MainDeadlineRig(), app = VisibilityNode(root: "app", own: .hidden)
        let updater = Self.updater(rig, checkNode: app)
        #expect(updater.stagedRefresh.timer.alignment.node === app, "the staged update's probe is not hidden-aligned")
        #expect(updater.stagedRefresh.timer.workClass == .background)
        #expect(updater.stagedRefresh.clickTimer.alignment.node == nil, "a deadline the person waits on is hidden-aligned")
        #expect(updater.stagedRefresh.clickTimer.workClass == .userBlocking)
    }

    @Test func theCardDeadlinesAreVisible() {
        let updater = Self.updater(MainDeadlineRig())
        #expect([updater.cardTimer.workClass, updater.installTimer.workClass, updater.snoozeTimer.workClass] == [.visible, .visible, .visible])
    }

    // MARK: R-hop (the feed read's landing)

    @Test func aFeedReadLandsInItsFrameNotBefore() async throws {
        let rig = MainDeadlineRig(), feed = Base.CountingFeed(xml: TipUpdateCheckTests.feed)
        let updater = Self.updater(rig, feed: feed)
        var answered: [String?] = []
        let task = updater.probe(.visible) { answered.append($0) }
        try #require(await Self.eventually { rig.work.postedCount(.visible) > 0 }, "the read's result was never posted")
        #expect(feed.fetches == 1)
        #expect(updater.lastProbe == nil, "the read's result landed before its frame")
        #expect(answered.isEmpty)
        rig.frame()
        #expect(updater.lastProbe != nil, "the frame did not land the read's result")
        #expect(answered == [nil], "the waiter did not get the read's answer in the landing")
        _ = await task.value
        #expect(!updater.isProbing)
    }

    // MARK: Coalesced progress (the channel switch's phases)

    /// A DMG download reports a phase per write: only the first of a burst asks for a main-thread apply, and the
    /// apply takes the newest phase, so the switch costs one visible task per frame, not one per write.
    @Test func aSwitchsDownloadProgressPostsOneApplyWithTheNewestPhase() {
        let phases = SwitchPhaseMailbox()
        #expect(phases.put(.downloading(fractionCompleted: nil)), "the first phase asked for no apply")
        let extraApplies = (1...1_000).filter { phases.put(.downloading(fractionCompleted: Double($0) / 1_000)) }.count
        #expect(extraApplies == 0, "a burst of progress posted \(extraApplies) more main-thread applies")
        #expect(phases.take() == .downloading(fractionCompleted: 1), "the apply did not take the newest phase")
        #expect(phases.take() == nil, "a phase was applied twice")
        #expect(phases.put(.verifying), "a phase after the apply ran asked for no apply")
    }

    // MARK: MainDeadline background (the recovery draft's debounce)

    @Test func aRecoveryDraftsDebounceIsABackgroundDeadline() throws {
        let rig = MainDeadlineRig()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-draft-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let drafts = RecoveryDraftStore(directory: directory, deadlines: rig.deadlines, work: BackgroundWork(label: "test.recovery-drafts"))
        let id = QuitParticipantID.file(path: "/tmp/a.txt")
        #expect(drafts.update(id: id, title: "a.txt", contents: Data("a".utf8)) == .kept)
        #expect(rig.hasArmedWake, "the debounce armed no wake on the main thread's queue")
        rig.fireAndRun()
        #expect(Self.classes(rig, "RecoveryDraftStore.debounce") == [.background])
    }

    // MARK: MainDeadline + postFromAnyThread (the WebKit setup probe)

    @Test func aWedgedWebKitProbeTimesOutOnABackgroundDeadline() {
        let rig = MainDeadlineRig()
        let gate = WebKitSetupGate(deadlines: rig.deadlines)
        gate.request = { Thread.sleep(forTimeInterval: 600) }
        gate.probe {}
        #expect(gate.state == .probing)
        rig.advance(by: WebKitSetupGate.timeout)
        rig.fireAtNow()
        #expect(gate.state == .slow, "the timeout did not mark the setup slow")
        #expect(Self.classes(rig, "WebKitSetupGate.timeout") == [.background])
    }

    static func classes(_ rig: MainDeadlineRig, _ owner: String) -> Set<MainWorkClass> {
        Set(rig.work.budget.board.ownerSnapshot().owners.filter { $0.owner == owner }.map(\.workClass))
    }
}
