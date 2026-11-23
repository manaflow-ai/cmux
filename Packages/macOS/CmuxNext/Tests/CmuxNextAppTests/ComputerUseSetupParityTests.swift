import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextOnboarding
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// What the Computer Use window does as the earlier cmux app's setup did: the done view after the
/// person's Allow got the last grant on, which closes the window by itself (and a manual close
/// cancels that), the Screenshots row's screen capture note, an entry that opens the window at one
/// grant and starts its Allow once the grants are read, and an agent's open that never takes the
/// keys (the Dock icon bounces while another app is active).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComputerUseSetupParityTests {
    /// The done view's delay ends at once.
    private nonisolated struct InstantClock: Clock {
        typealias Instant = ContinuousClock.Instant
        var now: Instant { ContinuousClock.now }
        var minimumResolution: Duration { .nanoseconds(1) }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try Task.checkCancellation()
        }
    }

    /// The done view's delay never ends by itself: only a cancel ends the wait.
    private nonisolated struct HeldClock: Clock {
        typealias Instant = ContinuousClock.Instant
        var now: Instant { ContinuousClock.now }
        var minimumResolution: Duration { .nanoseconds(1) }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            // A stream nothing feeds (its continuation kept alive here): its iteration ends only
            // when the task is cancelled.
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            for await _ in stream {}
            try Task.checkCancellation()
        }
    }

    @Observable final class Ended {
        var count = 0
    }

    private func window(_ current: ComputerUsePermissions, clock: any Clock<Duration>)
        -> (MockComputerUsePermissionSource, OnboardingModel, Ended) {
        let services = MockOnboardingServices()
        let source = MockComputerUsePermissionSource(current: current)
        services.computerUseSource = source
        let window = OnboardingModel(services: services, step: .computerUse, clock: clock)
        let ended = Ended()
        window.onEnd = { if $0 { ended.count += 1 } }
        window.stepDidAppear()
        return (source, window, ended)
    }

    /// Waits until the model applied what the source pushed.
    private func settle(_ model: ComputerUseStepModel, _ condition: @MainActor () -> Bool) async {
        for await _ in ObservationStream({ model.permissions }) where condition() { return }
    }

    private func page(_ window: OnboardingModel) -> OnboardingPageState.ComputerUse? {
        OnboardingPageState(model: window, images: OnboardingPageImages()).computerUse
    }

    // MARK: The done view

    @Test func theLastGrantAfterThePersonsAllowShowsTheDoneViewAndClosesTheWindow() async {
        let (source, window, ended) = self.window(ComputerUsePermissions(accessibility: true, screenRecording: false), clock: InstantClock())
        defer { window.leave() }
        let model = window.computerUse
        await settle(model) { model.permissions.accessibility }
        #expect(!model.finished)
        model.allow(.screenRecording)
        source.current.screenRecording = true
        for await count in ObservationStream({ ended.count }) where count == 1 { break }
        #expect(model.finished, "the done view showed")
        #expect(window.ended, "the window ended as Done by itself")
    }

    @Test func theDoneViewWaitsItsDelayAndAManualCloseCancelsIt() async {
        let (source, window, ended) = self.window(ComputerUsePermissions(accessibility: true, screenRecording: false), clock: HeldClock())
        let model = window.computerUse
        await settle(model) { model.permissions.accessibility }
        model.allow(.screenRecording)
        source.current.screenRecording = true
        await settle(model) { model.permissions.screenRecording }
        #expect(model.finished)
        #expect(model.closeTimer.isScheduled, "the done view's close is pending")
        #expect(page(window)?.finished == true)
        #expect(ended.count == 0)
        window.leave()
        #expect(!model.closeTimer.isScheduled, "the close button cancels the timed close")
        #expect(ended.count == 0, "a manual close is not Done")
    }

    @Test func aWindowOpenedReadyKeepsItsRowsAndStaysOpen() async {
        let (_, window, ended) = self.window(ComputerUsePermissions(accessibility: true, screenRecording: true), clock: InstantClock())
        defer { window.leave() }
        let model = window.computerUse
        await settle(model) { model.allGranted }
        #expect(!model.finished)
        #expect(!model.closeTimer.isScheduled)
        #expect(page(window)?.finished == false)
        #expect(page(window)?.allGranted == true, "the ready line and Done, as before")
        #expect(ended.count == 0)
    }

    @Test func aRevokedGrantDuringTheDoneViewCancelsTheClose() async {
        let (source, window, ended) = self.window(ComputerUsePermissions(accessibility: true, screenRecording: false), clock: HeldClock())
        defer { window.leave() }
        let model = window.computerUse
        await settle(model) { model.permissions.accessibility }
        model.allow(.screenRecording)
        source.current.screenRecording = true
        await settle(model) { model.permissions.screenRecording }
        #expect(model.closeTimer.isScheduled)
        source.current.screenRecording = false
        await settle(model) { !model.permissions.screenRecording }
        #expect(!model.finished)
        #expect(!model.closeTimer.isScheduled)
        #expect(ended.count == 0)
    }

    // MARK: Screen capture confirmation

    @Test func screenshotsAllowedHereShowsTheCaptureNoteOnceItsGrantLands() async {
        let (source, window, _) = self.window(.none, clock: HeldClock())
        defer { window.leave() }
        let model = window.computerUse
        await settle(model) { true }
        model.allow(.screenRecording)
        #expect(!model.confirmsCapture, "not before the grant")
        source.current.screenRecording = true
        await settle(model) { model.permissions.screenRecording }
        #expect(model.confirmsCapture)
        #expect(page(window)?.confirmsCapture == true)
        #expect(!model.finished, "Accessibility still waits")
    }

    @Test func screenRecordingGrantedElsewhereShowsNoCaptureNote() async {
        let (source, window, _) = self.window(.none, clock: HeldClock())
        defer { window.leave() }
        let model = window.computerUse
        await settle(model) { true }
        model.allow(.accessibility)
        source.current.screenRecording = true
        await settle(model) { model.permissions.screenRecording }
        #expect(!model.confirmsCapture)
    }

    // MARK: Entries that open the window at a grant

    @Test func aGrantEntryStartsItsAllowOnceTheGrantsAreRead() async {
        let source = MockComputerUsePermissionSource(current: .reading)
        let model = ComputerUseStepModel(source: source, clock: HeldClock())
        defer { model.stop() }
        model.allowOnceKnown(.screenRecording)
        model.start()
        await settle(model) { model.permissions.isReading }
        #expect(source.opened.isEmpty, "grants still being read start nothing")
        source.current = ComputerUsePermissions(accessibility: true, screenRecording: false)
        await settle(model) { !model.permissions.isReading }
        #expect(source.opened == [.screenRecording])
        #expect(model.helping == .screenRecording, "the drag panel shows")
    }

    @Test func aGrantEntryForAGrantAlreadyOnOpensNothing() async {
        let source = MockComputerUsePermissionSource(current: ComputerUsePermissions(accessibility: true, screenRecording: false))
        let model = ComputerUseStepModel(source: source, clock: HeldClock())
        defer { model.stop() }
        model.start()
        await settle(model) { model.permissions.accessibility }
        model.allowOnceKnown(.accessibility)
        #expect(source.opened.isEmpty)
        model.allowOnceKnown(.screenRecording)
        #expect(source.opened == [.screenRecording], "an open window starts the grant's Allow at once")
    }

    @Test func aGrantEntryWithAFailedHelperOpensNothing() async {
        let source = MockComputerUsePermissionSource(current: .helperFailed)
        let model = ComputerUseStepModel(source: source, clock: HeldClock())
        defer { model.stop() }
        model.allowOnceKnown(.accessibility)
        model.start()
        await settle(model) { model.permissions.helperFailed }
        #expect(source.opened.isEmpty)
        #expect(model.helping == nil)
    }

    // MARK: An agent's open

    @Test func anAgentsOpenComesForwardWithoutTheKeysAndThePersonsTakesThem() {
        let presenter = OnboardingWindowPresenter(makeModel: { step in
            let services = MockOnboardingServices()
            services.computerUseSource = MockComputerUsePermissionSource()
            return OnboardingModel(services: services, step: step)
        }, activeLook: nil, present: { _ in })
        presenter.show(step: .computerUse, quietly: true)
        let first = presenter.controller
        defer { first?.close() }
        #expect(first?.presentsQuietly == true)
        presenter.show(step: .computerUse)
        #expect(presenter.controller === first, "the open window is reused")
        #expect(first?.presentsQuietly == false, "the person's own open takes the keys")
    }

    @Test func aQuietOpenNeverTakesTheKeysAndBouncesOnlyWhileAnotherAppIsActive() {
        let quiet = OnboardingWindowController.intent(quietly: true)
        #expect(quiet == .bringForward)
        let plan = WindowActivation.plan(quiet, noActivate: false, testScreen: false)
        #expect(plan.order != .makeKeyAndOrderFront && !plan.activatesApp, "never key, never activates cmux")
        #expect(OnboardingWindowController.intent(quietly: false) == .present)
        #expect(OnboardingWindowController.asksForAttention(quietly: true, appIsActive: false, noActivate: false))
        #expect(!OnboardingWindowController.asksForAttention(quietly: true, appIsActive: true, noActivate: false),
                "cmux in front already shows the window")
        #expect(!OnboardingWindowController.asksForAttention(quietly: true, appIsActive: false, noActivate: true))
        #expect(!OnboardingWindowController.asksForAttention(quietly: false, appIsActive: false, noActivate: false),
                "the person's own open needs no bounce")
    }
}
