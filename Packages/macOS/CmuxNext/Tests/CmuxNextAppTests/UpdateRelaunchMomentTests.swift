import AppKit
import CmuxNextCompat
import Foundation
import CmuxNextTestSupport
@testable import CmuxNextUpdater
import CmuxNextWakeupsTestSupport
import Testing

/// An automatic install never relaunches while a modal or sheet is up, a menu is open, or text is
/// mid-composition, and installs at the first moment none holds (Leo, 2026-10-26: "if the nightly is
/// post, I just want it. Just give it to me. Don't wait. Like, stop waiting."). Nothing else holds it:
/// not a hidden window, and not past its bound in silence.
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
                                     defaults: UserDefaults(testSuiteName: "UpdateRelaunchMomentTests.\(UUID().uuidString)")!,
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

    // MARK: Only what a person could lose or is looking at holds (audit 2026-11-18 #17)

    /// A window that is not on screen or in the Dock (a parked spare, a hidden page window) holds
    /// nothing: its sheet or composition is nothing a relaunch cuts off where anyone looks. Before,
    /// any window's sheet or marked text held the install, with no end.
    @Test func aHiddenWindowsSheetOrCompositionDoesNotHold() {
        let hidden = UpdateRelaunchMoment(modal: false, tracking: false, windows: [
            .init(isShown: false, hasSheet: true),
            .init(isShown: false, hasMarkedText: true),
            .init(isShown: true),
        ])
        #expect(hidden.interruption == nil)
        let shownSheet = UpdateRelaunchMoment(modal: false, tracking: false, windows: [.init(isShown: false), .init(isShown: true, hasSheet: true)])
        #expect(shownSheet.interruption == .sheet)
        let shownComposing = UpdateRelaunchMoment(modal: false, tracking: false, windows: [.init(isShown: true, hasMarkedText: true)])
        #expect(shownComposing.interruption == .composing)
    }

    /// The live read: a real window that was never ordered front, whose text view holds marked
    /// text, does not hold the install.
    @Test func aHiddenWindowWithMarkedTextDoesNotHoldTheLiveMoment() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = text
        try #require(window.makeFirstResponder(text))
        text.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        // The control: the window really composes, and is really hidden.
        try #require(text.hasMarkedText())
        try #require(!window.isVisible)

        #expect(UpdateRelaunchMoment.Window(window) == .init(isShown: false))
        #expect(!UpdateRelaunchMoment.current().composing, "a hidden window's marked text held the automatic install")
    }

    // MARK: A hold has a bound, and says why it waits

    /// Past ``UpdateRelaunchMomentHold/surfaceAfter`` the hold stops waiting silently: its typed
    /// state says why and for how long, one log line says so, and it still never installs over
    /// what is open. It installs by itself the second that ends.
    @Test func aHoldPastItsBoundSurfacesWithItsReasonAndNeverRelaunchesOverIt() async throws {
        let clock = ManualClock()
        let moment = Moment()
        moment.now.sheet = true
        var date = Date(timeIntervalSince1970: 1_000_000)
        var lines: [String] = []
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: clock, now: { date }, log: { lines.append($0) })
        hold.surfaceAfter = .seconds(600)
        var installs = 0
        #expect(hold.hold { installs += 1 })
        #expect(hold.state == UpdateRelaunchHoldState(reason: .sheet, since: date))

        // A minute in: still silent. Both deadlines (the 1 s recheck and the bound) are set first.
        for _ in 0..<1_000 where clock.sleeperDeadlines.count < 2 { await Task.yield() }
        try #require(clock.sleeperDeadlines.count == 2)
        date += 60
        clock.advance(by: .seconds(60))
        await settle()
        #expect(hold.state?.surfaced == false)

        // At the bound: surfaced, with its reason now and its age, and nothing installed.
        moment.now.sheet = false
        moment.now.modal = true
        date += 540
        clock.advance(by: .seconds(540))
        for _ in 0..<1_000 where hold.state?.surfaced != true { await Task.yield() }
        let held = try #require(hold.state)
        #expect(held.surfaced)
        #expect(held.reason == .modal)
        #expect(held.age(at: date) == 600)
        #expect(installs == 0)
        #expect(hold.isHolding)
        #expect(lines.contains { $0.hasPrefix("automatic install held 600 s: a modal is up") })

        // The modal ends: it installs by itself, and the state goes.
        moment.now.modal = false
        try await clock.waitForSleeper()
        clock.advance(by: UpdateRelaunchMomentHold.recheckInterval)
        for _ in 0..<1_000 where installs == 0 { await Task.yield() }
        #expect(installs == 1)
        #expect(hold.state == nil)
    }

    /// A hold dropped before its bound never surfaces later.
    @Test func aCancelledHoldNeverSurfaces() async {
        let clock = ManualClock()
        let moment = Moment()
        moment.now.sheet = true
        let hold = UpdateRelaunchMomentHold(moment: { moment.now }, clock: clock)
        hold.surfaceAfter = .seconds(600)
        #expect(hold.hold {})
        hold.cancel()
        #expect(hold.state == nil)
        clock.advance(by: .seconds(600))
        await settle()
        #expect(hold.state == nil)
    }

    /// The staged update card says why a surfaced hold waits (its popover's headline); its title
    /// and its Restart to Update button stay as they are.
    @Test func theReadyCardSaysWhyASurfacedHoldWaits() {
        let notes = UpdateReadyNotes(version: "1.0.0", notes: nil, fullNotesURL: nil)
        let quiet = UpdateReadyCard(version: "1.0.0", isInstalling: false, automaticUpdates: true, notes: notes)
        let held = UpdateReadyCard(version: "1.0.0", isInstalling: false, automaticUpdates: true, notes: notes, heldBy: .sheet)
        #expect(held.heldBy == .sheet)
        #expect(held.notes.headline == UpdaterStrings.heldHeadline(.sheet))
        #expect(held.notes.headline != quiet.notes.headline)
        #expect(held.buttonTitle == quiet.buttonTitle)
        #expect(held.title == quiet.title)
    }
}
