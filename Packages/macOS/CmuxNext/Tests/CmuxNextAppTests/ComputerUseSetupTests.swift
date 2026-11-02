import AppKit
import CmuxNextAgentActivity
import CmuxNextCompat
@testable import CmuxNextOnboarding
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComputerUseSetupTests {
    private actor Reader {
        var count = 0
        var result: ComputerUseSetup.Read = .noAnswer

        func read() -> ComputerUseSetup.Read {
            count += 1
            return result
        }

        func answer() {
            result = .answered(ComputerUsePermissions(accessibility: true, screenRecording: true), helper: nil)
        }

        func setResult(_ value: ComputerUseSetup.Read) {
            result = value
        }
    }

    /// Retry delays end at once, without wall time or a sleep used to settle work.
    private nonisolated struct RetryClock: Clock {
        typealias Instant = ContinuousClock.Instant
        var now: Instant { ContinuousClock.now }
        var minimumResolution: Duration { .nanoseconds(1) }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try Task.checkCancellation()
        }
    }

    @Observable final class InputBox {
        var value = ComputerUseSetup.Inputs(disabledByPolicy: false, enabled: true, helper: .running(42))
        var restarts = 0
    }

    private func make(_ box: InputBox, _ reader: Reader,
                      notifications: NotificationCenter = NotificationCenter(),
                      distributed: NotificationCenter = NotificationCenter()) -> ComputerUseSetup {
        ComputerUseSetup(inputs: { box.value },
                         configuration: { .init(socketPath: "/unused/cua.sock", authToken: nil, machineName: "") },
                         read: { _ in await reader.read() },
                         resolveHelper: { _ in nil },
                         restartHelper: {
                             box.restarts += 1
                             await reader.answer()
                         },
                         notifications: notifications, distributed: distributed, clock: RetryClock())
    }

    private func wait(_ setup: ComputerUseSetup, for phase: ComputerUseSetup.Phase) async {
        for await value in ObservationStream({ setup.phase }) {
            if value == phase { return }
        }
    }

    @Test func noAnswerUsesSixReadsThenReportsFailureEverywhere() async {
        let reader = Reader()
        let setup = make(InputBox(), reader)
        setup.start()
        await wait(setup, for: .failed)
        #expect(await reader.count == ComputerUseSetup.maximumRetries)
        #expect(setup.phase.rawValue == "failed")
        #expect(setup.stepPermissions.helperFailed)
        #expect(setup.pageJSON["phase"] == .string("failed"))
        #expect(setup.pageJSON["accessibility"] == .null)
        #expect(setup.pageJSON["screen_recording"] == .null)
    }

    /// The legacy helper refusing this build as its consent host shows on the card under the
    /// legacy driver only.
    @Test func anUnverifiedConsentHostShowsUnderTheLegacyDriver() async {
        let box = InputBox()
        box.value.consentHostUnverified = true
        let setup = make(box, Reader())
        setup.start()
        #expect(setup.pageJSON["host_unverified"] == .bool(true))
        box.value.driver = .upstream
        for await value in ObservationStream({ setup.hostUnverified }) where !value { break }
        #expect(setup.pageJSON["host_unverified"] == .bool(false))
    }

    /// Driver "upstream" in a build without the helper v2: the legacy helper that runs is read,
    /// Restart Helper restarts it, and the status says plainly that Legacy runs in its place.
    @Test func anUpstreamFallbackReadsTheLegacyHelperAndSaysSo() async {
        let box = InputBox()
        box.value.upstreamFallback = true
        let reader = Reader()
        await reader.answer()
        let setup = make(box, reader)
        setup.start()
        await wait(setup, for: .ready)
        #expect(setup.pageJSON["driver"] == .string("legacy"))
        #expect(setup.pageJSON["upstream_fallback"] == .bool(true))
        #expect(setup.pageJSON["note"] == .string("Upstream helper isn't in this build; using Legacy"))
        #expect(setup.prepareRestart() != nil, "Restart Helper restarts the legacy helper that runs")
        box.value.enabled = false
        for await value in ObservationStream({ setup.upstreamFallback }) where !value { break }
        #expect(setup.pageJSON["upstream_fallback"] == .bool(false))
        #expect(setup.pageJSON["note"] == .null)
    }

    @Test func recheckStartsANewReadBudget() async {
        let reader = Reader()
        let setup = make(InputBox(), reader)
        setup.start()
        await wait(setup, for: .failed)
        setup.recheck()
        #expect(setup.phase == .starting)
        await wait(setup, for: .failed)
        #expect(await reader.count == 2 * ComputerUseSetup.maximumRetries)
    }

    @Test(arguments: ["activation", "trust", "input", "recheck"])
    func aLaterAnswerRecoversOnEachExistingTrigger(_ trigger: String) async {
        let reader = Reader()
        let box = InputBox()
        let notifications = NotificationCenter()
        let distributed = NotificationCenter()
        let setup = make(box, reader, notifications: notifications, distributed: distributed)
        setup.start()
        await wait(setup, for: .failed)
        await reader.answer()
        switch trigger {
        case "activation": notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        case "trust": distributed.post(name: ComputerUseSetup.accessibilityTrustChanged, object: nil)
        case "input": box.value.helper = .running(43)
        default: setup.recheck()
        }
        await wait(setup, for: .ready)
        #expect(setup.permissions.accessibility && setup.permissions.screenRecording)
        #expect(!setup.stepPermissions.helperFailed)
    }

    @Test func restartShowsProgressThenReadsTheRestartedHelper() async throws {
        let reader = Reader()
        let box = InputBox()
        let setup = make(box, reader)
        setup.start()
        await wait(setup, for: .failed)
        let restart = try #require(setup.prepareRestart())
        #expect(setup.phase == .starting)
        await restart()
        await wait(setup, for: .ready)
        #expect(box.restarts == 1)
        #expect(await reader.count == ComputerUseSetup.maximumRetries + 1)
    }

    @Test func aPendingRestartDoesNotRunAfterPolicyTurnsComputerUseOff() async throws {
        let reader = Reader()
        let box = InputBox()
        let setup = make(box, reader)
        setup.start()
        await wait(setup, for: .failed)
        let restart = try #require(setup.prepareRestart())
        box.value.disabledByPolicy = true
        await restart()
        #expect(box.restarts == 0)
        await wait(setup, for: .disabledByPolicy)
    }

    @Test func onboardingRestartUsesTheSharedSetup() async {
        let reader = Reader()
        let box = InputBox()
        let setup = make(box, reader)
        setup.start()
        await wait(setup, for: .failed)
        let source = AppComputerUsePermissionSource(setup: setup)
        let model = ComputerUseStepModel(source: source)
        model.start()
        defer { model.stop() }
        for await permissions in ObservationStream({ model.permissions }) {
            if permissions.helperFailed { break }
        }
        model.restart()
        #expect(setup.phase == .starting)
        await wait(setup, for: .ready)
        #expect(box.restarts == 1)
    }

    /// On macOS 26 the Screen Recording toggle alone leaves the helper's capture
    /// check false until the helper itself asks once (seen 2026-10-27). Allow must
    /// send that host-only request to the running helper, then open System Settings.
    @Test func allowAsksTheRunningHelperToRequestTheGrant() async {
        let reader = Reader()
        await reader.setResult(.answered(ComputerUsePermissions(accessibility: true, screenRecording: false), helper: nil))
        let box = InputBox()
        let requests = GrantRequests()
        var opened: [URL] = []
        let setup = ComputerUseSetup(inputs: { box.value },
                                     configuration: { .init(socketPath: "/unused/cua.sock", authToken: "a", hostAuthToken: "h",
                                                            machineName: "") },
                                     read: { _ in await reader.read() },
                                     resolveHelper: { _ in nil },
                                     openURL: { opened.append($0) },
                                     requestGrant: { _, pane in await requests.add(pane) },
                                     notifications: NotificationCenter(), distributed: NotificationCenter(), clock: RetryClock())
        setup.start()
        await wait(setup, for: .ready)
        // Accessibility sends no request: it would raise macOS's alert over the drag panel.
        setup.open(.accessibility)
        setup.open(.screenRecording)
        for await count in ObservationStream({ requests.count }) where count == 1 { break }
        #expect(await requests.panes == [.screenRecording])
        #expect(opened.count == 2)

        // Off: no helper runs, so only System Settings opens.
        box.value = ComputerUseSetup.Inputs(disabledByPolicy: false, enabled: false, helper: .off)
        await wait(setup, for: .off)
        setup.open(.accessibility)
        #expect(await requests.panes == [.screenRecording])
        #expect(opened.count == 3)
    }

    /// The helper exited and the daemon started another (macOS "Quit & Reopen"
    /// after a Screen Recording grant). The new helper has not answered: the old
    /// grants must not stay "ready", and its own answer brings the new grant.
    @Test func anotherHelperReadsItsGrantsFromStarting() async {
        let reads = GatedReads()
        let box = InputBox()
        let setup = ComputerUseSetup(inputs: { box.value },
                                     configuration: { .init(socketPath: "/unused/cua.sock", authToken: nil, machineName: "") },
                                     read: { _ in await reads.read() },
                                     resolveHelper: { _ in nil },
                                     notifications: NotificationCenter(), distributed: NotificationCenter(), clock: RetryClock())
        setup.start()
        for await waiting in ObservationStream({ reads.waiting }) where waiting { break }
        reads.answer(.answered(ComputerUsePermissions(accessibility: true, screenRecording: false), helper: nil))
        await wait(setup, for: .ready)

        box.value.helper = .running(43)
        for await waiting in ObservationStream({ reads.waiting }) where waiting { break }
        #expect(setup.phase == .starting)
        #expect(setup.pageJSON["screen_recording"] == .null)

        reads.answer(.answered(ComputerUsePermissions(accessibility: true, screenRecording: true), helper: nil))
        await wait(setup, for: .ready)
        #expect(setup.permissions.screenRecording)
    }

    /// The helper kept exiting (the daemon stopped restarting it): the setup
    /// shows its failed state, where Restart Helper starts it again.
    @Test func aHelperThatKeepsExitingShowsFailedWithRestart() async throws {
        let box = InputBox()
        box.value.helper = .failed
        let setup = make(box, Reader())
        setup.start()
        #expect(setup.phase == .failed)
        #expect(setup.stepPermissions.helperFailed)
        let restart = try #require(setup.prepareRestart())
        await restart()
        #expect(box.restarts == 1)
    }

    /// Reads that wait until the test answers them.
    @MainActor @Observable final class GatedReads {
        private(set) var waiting = false
        @ObservationIgnored private var pending: CheckedContinuation<ComputerUseSetup.Read, Never>?

        func read() async -> ComputerUseSetup.Read {
            await withCheckedContinuation {
                pending = $0
                waiting = true
            }
        }

        func answer(_ read: ComputerUseSetup.Read) {
            waiting = false
            pending?.resume(returning: read)
            pending = nil
        }
    }

    /// With Accessibility off, the helper's capture request also raised macOS's Accessibility
    /// alert: Allow on Screenshots then only opens System Settings.
    @Test func screenshotsAllowAsksTheHelperOnlyOnceAccessibilityIsOn() {
        #expect(!ComputerUseSetup.asksHelper(.screenRecording, accessibility: false, phase: .ready, driver: .legacy))
        #expect(ComputerUseSetup.asksHelper(.screenRecording, accessibility: true, phase: .ready, driver: .legacy))
        #expect(!ComputerUseSetup.asksHelper(.accessibility, accessibility: true, phase: .ready, driver: .legacy))
        #expect(!ComputerUseSetup.asksHelper(.screenRecording, accessibility: true, phase: .off, driver: .legacy))
        #expect(!ComputerUseSetup.asksHelper(.screenRecording, accessibility: true, phase: .ready, driver: .upstream))
    }

    actor GrantRequestsStore {
        var panes: [ComputerUsePermissionPane] = []
        func add(_ pane: ComputerUsePermissionPane) { panes.append(pane) }
    }

    @MainActor @Observable final class GrantRequests {
        var count = 0
        private let store = GrantRequestsStore()
        var panes: [ComputerUsePermissionPane] { get async { await store.panes } }
        nonisolated func add(_ pane: ComputerUsePermissionPane) async {
            await store.add(pane)
            await MainActor.run { count += 1 }
        }
    }
}
