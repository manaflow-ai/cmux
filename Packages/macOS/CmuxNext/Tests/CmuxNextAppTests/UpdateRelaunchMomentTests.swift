import AppKit
import CmuxNextCompat
@testable import CmuxNextUpdater
import CmuxNextWakeupsTestSupport
import Testing

/// An automatic install never relaunches while a modal or sheet is up, a menu is open, or text is
/// mid-composition, and installs at the first moment none holds (Leo, 2026-10-26: "if the nightly is
/// post, I just want it. Just give it to me. Don't wait. Like, stop waiting."). Nothing else holds it.
@MainActor @Suite(.serialized) struct UpdateRelaunchMomentTests {
    /// The moment the hold reads, set by the test.
    @MainActor private final class Moment {
        var now = UpdateRelaunchMoment()
    }

    /// Lets main-actor work that is ready run.
    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test func eachInterruptionHoldsAndNothingElseDoes() {
        #expect(UpdateRelaunchMoment().interruption == nil)
        #expect(UpdateRelaunchMoment(modal: true).interruption != nil)
        #expect(UpdateRelaunchMoment(sheet: true).interruption != nil)
        #expect(UpdateRelaunchMoment(tracking: true).interruption != nil)
        #expect(UpdateRelaunchMoment(composing: true).interruption != nil)
    }

    @Test func aClearMomentInstallsAtOnce() {
        let moment = Moment()
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: ManualClock())
        var installs = 0
        #expect(!hold.hold { installs += 1 })
        #expect(!hold.isHolding)
        #expect(installs == 0) // the caller installs
    }

    @Test func aSheetHoldsUntilItEnds() async throws {
        let clock = ManualClock()
        let moment = Moment()
        moment.now.sheet = true
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: clock)
        var installs = 0
        #expect(hold.hold { installs += 1 })

        try await clock.waitForSleeper()
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        try await clock.waitForSleeper() // the sheet is still up: it looks again a second later
        #expect(installs == 0)

        moment.now.sheet = false
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        for _ in 0..<1_000 where installs == 0 { await Task.yield() }
        #expect(installs == 1)
        #expect(!hold.isHolding)

        // Its timer is gone: a later recheck installs nothing again.
        hold.recheck()
        await settle()
        #expect(installs == 1)
    }

    /// While an update waits, an event-loop pass costs nothing. AppKit posts
    /// `NSApplication.didUpdateNotification` after every event, and the hold started a main-actor
    /// Task that read the moment on each one (#25910): the wait is one 1 s recheck, nothing per pass.
    @Test func eventLoopPassesDoNoWorkWhileAnUpdateWaits() async {
        let moment = Moment()
        moment.now.sheet = true
        var reads = 0
        let hold = UpdateRelaunchMomentHold(moment: {
            reads += 1
            return moment.now
        }, clock: ManualClock())
        #expect(hold.hold {})
        let readsToHold = reads
        // The control: each pass really announces itself, as AppKit's event loop does after each event.
        var announced = 0
        let passes = MainActorObservation(NSApplication.didUpdateNotification) { announced += 1 }
        defer { passes.cancel() }

        for _ in 0..<100 { NSApplication.shared.updateWindows() }
        await settle()
        #expect(announced >= 100, "updateWindows() announced \(announced) of 100 passes")
        #expect(reads == readsToHold, "100 event-loop passes read the moment \(reads - readsToHold) times")
        hold.cancel()
    }

    @Test func compositionThatEndsWithoutAnEventIsCaughtWithinASecond() async throws {
        let clock = ManualClock()
        let moment = Moment()
        moment.now.composing = true
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: clock)
        var installs = 0
        #expect(hold.hold { installs += 1 })

        try await clock.waitForSleeper()
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        try await clock.waitForSleeper() // still composing: it looks again a second later
        #expect(installs == 0)

        moment.now.composing = false
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        for _ in 0..<1_000 where installs == 0 { await Task.yield() }
        #expect(installs == 1)
        #expect(!hold.isHolding)
    }

    @Test func aMenuOrModalHoldsThroughRechecksAndCancelRunsNothing() async throws {
        let clock = ManualClock()
        let moment = Moment()
        moment.now.tracking = true
        moment.now.modal = true
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: clock)
        var installs = 0
        #expect(hold.hold { installs += 1 })

        moment.now.tracking = false
        try await clock.waitForSleeper()
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        try await clock.waitForSleeper()
        #expect(installs == 0) // the modal still holds

        hold.cancel()
        moment.now.modal = false
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        hold.recheck()
        await settle()
        #expect(installs == 0)
    }

    @Test func aNewerHoldReplacesTheOlder() {
        let moment = Moment()
        moment.now.sheet = true
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: ManualClock())
        var first = 0, second = 0
        #expect(hold.hold { first += 1 })
        #expect(hold.hold { second += 1 })

        moment.now.sheet = false
        hold.recheck()
        #expect(first == 0)
        #expect(second == 1)
    }

    @Test func theUpdaterHoldsAnAutomaticInstallOnlyWhileTheMomentIsBusy() {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.relaunch-moment", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     defaults: UserDefaults(suiteName: "UpdateRelaunchMomentTests.\(UUID().uuidString)")!,
                                     enableSparkle: false, recordsUpdates: false)
        // The test runner has no modal, sheet, menu or composition up: the install starts now.
        // Called outside #expect: the macro passes a call's arguments through a @Sendable closure, and
        // the `{}` it would capture is a plain (non-Sendable) closure there, not the @MainActor one the
        // method takes, which Swift 6 refuses to compile.
        let defers = updater.updaterDefersAutomaticInstall(until: {})
        #expect(!defers)
        #expect(!updater.relaunchMomentHold.isHolding)
    }

    /// The self-quit (UpdateRelaunchBehind) waits for the moment too: the quit ends every sheet.
    @Test func theSelfQuitWaitsUntilTheSheetEnds() async {
        let moment = Moment()
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: ManualClock())
        #expect(await hold.waitUntilClear()) // nothing up: at once

        moment.now.sheet = true
        var answer: Bool?
        let waiting = Task { @MainActor in answer = await hold.waitUntilClear() }
        await settle()
        #expect(answer == nil)
        moment.now.sheet = false
        hold.recheck()
        await waiting.value
        #expect(answer == true)
    }

    @Test func aDroppedSelfQuitWaitAnswersNo() async {
        let moment = Moment()
        moment.now.composing = true
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: ManualClock())
        var answer: Bool?
        let waiting = Task { @MainActor in answer = await hold.waitUntilClear() }
        await settle()
        hold.cancel()
        await waiting.value
        #expect(answer == false)
    }

    /// A sheet that comes up again before the waiting quit resumes keeps it waiting.
    @Test func theSelfQuitChecksAgainWhenItResumes() async {
        let moment = Moment()
        moment.now.sheet = true
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: ManualClock())
        var answer: Bool?
        let waiting = Task { @MainActor in answer = await hold.waitUntilClear() }
        await settle()
        moment.now.sheet = false
        hold.recheck() // releases the waiter...
        moment.now.sheet = true // ...and a sheet begins before it resumes
        await settle()
        #expect(answer == nil)
        #expect(hold.isHolding)
        moment.now.sheet = false
        hold.recheck()
        await waiting.value
        #expect(answer == true)
    }
}
