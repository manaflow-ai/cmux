import AppKit
import CmuxNextCompat
import CmuxNextMacScreen
@testable import CmuxNextOnboarding
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// Computer Use through cmux Remote (`computerUse.driver = upstream`, the default): turning it on
/// runs setup against cmux Remote's grants. Before, setup read only the legacy helper, so cmux
/// Remote stayed at Accessibility and Screen Recording off and nothing ever asked macOS (seen
/// 2026-11-04 on macOS 27.0.1 with a tagged dev build).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComputerUseRemoteSetupFlowTests {
    /// cmux Remote's grants as `refresh` reports them, and every request and pane opened, in order.
    @MainActor @Observable final class Host {
        var grants = ComputerUsePermissions(accessibility: false, screenRecording: false)
        private(set) var requested: [ComputerUsePermissionPane] = []
        private(set) var openedSettings: [ComputerUsePermissionPane] = []
        private(set) var reads = 0

        func read() -> ComputerUseSetup.Read {
            reads += 1
            return .answered(grants, helper: nil)
        }

        func request(_ pane: ComputerUsePermissionPane) { requested.append(pane) }
        func openSettings(_ pane: ComputerUsePermissionPane) { openedSettings.append(pane) }

        nonisolated var remote: ComputerUseSetup.RemoteHost {
            ComputerUseSetup.RemoteHost(read: { await self.read() },
                                        request: { pane in await self.request(pane) },
                                        openSettings: { pane in await self.openSettings(pane) })
        }
    }

    /// The card the flow shows, and the person's presses.
    @MainActor @Observable final class Cards: ComputerUseRemoteSetupPresenting {
        private(set) var shown: ComputerUseRemoteSetupCard?
        private(set) var shows = 0
        @ObservationIgnored private var answer: (@MainActor (String) -> Void)?

        func showSetup(_ card: ComputerUseRemoteSetupCard, answered: @escaping @MainActor (String) -> Void) {
            shown = card
            shows += 1
            answer = answered
        }

        func withdrawSetup() {
            shown = nil
            answer = nil
        }

        func press(_ button: String) { answer?(button) }
    }

    @Observable final class InputBox {
        var value = ComputerUseSetup.Inputs(disabledByPolicy: false, enabled: true, helper: .off, driver: .upstream, remote: true)
    }

    private struct Rig {
        let box: InputBox
        let host: Host
        let cards: Cards
        let setup: ComputerUseSetup
        let flow: ComputerUseRemoteSetupFlow
        let notifications: NotificationCenter
        let distributed: NotificationCenter
    }

    private func rig(_ inputs: ComputerUseSetup.Inputs? = nil) -> Rig {
        let box = InputBox()
        if let inputs { box.value = inputs }
        let host = Host()
        let cards = Cards()
        let notifications = NotificationCenter()
        let distributed = NotificationCenter()
        var legacyOpened: [URL] = []
        let setup = ComputerUseSetup(inputs: { box.value },
                                     configuration: { nil },
                                     read: { _ in .noAnswer },
                                     resolveHelper: { _ in nil },
                                     openURL: { legacyOpened.append($0) },
                                     notifications: notifications, distributed: distributed,
                                     remoteHost: host.remote)
        let flow = ComputerUseRemoteSetupFlow(setup: setup, presenter: cards)
        setup.start()
        flow.start()
        return Rig(box: box, host: host, cards: cards, setup: setup, flow: flow, notifications: notifications, distributed: distributed)
    }

    private func until(_ rig: Rig, _ step: ComputerUseRemoteSetupFlow.Step) async {
        for await value in ObservationStream({ rig.flow.step }) where value == step { return }
    }

    private func until(_ host: Host, requested count: Int) async {
        for await value in ObservationStream({ host.requested.count }) where value >= count { return }
    }

    // MARK: Decisions

    @Test func theStepFollowsCmuxRemotesGrants() {
        let off = ComputerUsePermissions(accessibility: false, screenRecording: false)
        let ax = ComputerUsePermissions(accessibility: true, screenRecording: false)
        let both = ComputerUsePermissions(accessibility: true, screenRecording: true)
        typealias Flow = ComputerUseRemoteSetupFlow
        // Not cmux Remote (the legacy helper, or the helper v2 without cmux Remote): nothing changes.
        #expect(Flow.step(remote: false, phase: .ready, permissions: off, continued: false) == .none)
        #expect(Flow.step(remote: false, phase: .ready, permissions: off, continued: true) == .none)
        // cmux Remote, grants not read yet.
        #expect(Flow.step(remote: true, phase: .starting, permissions: .none, continued: false) == .reading)
        // Off or policy: nothing to set up.
        #expect(Flow.step(remote: true, phase: .off, permissions: .none, continued: false) == .none)
        #expect(Flow.step(remote: true, phase: .disabledByPolicy, permissions: .none, continued: false) == .none)
        // Both off: the card asks first, then Accessibility, then Screen Recording, one at a time.
        #expect(Flow.step(remote: true, phase: .ready, permissions: off, continued: false) == .ask)
        #expect(Flow.step(remote: true, phase: .ready, permissions: off, continued: true) == .request(.accessibility))
        #expect(Flow.step(remote: true, phase: .ready, permissions: ax, continued: true) == .request(.screenRecording))
        // Granted: ready, with or without the card.
        #expect(Flow.step(remote: true, phase: .ready, permissions: both, continued: false) == .ready)
        #expect(Flow.step(remote: true, phase: .ready, permissions: both, continued: true) == .ready)
    }

    // MARK: The flow

    /// Both off: the card names the two permissions; Continue asks cmux Remote for Accessibility
    /// only; its grant (macOS's Accessibility change) asks for Screen Recording; that grant (the
    /// person comes back to cmux) closes the card and reports ready.
    @Test func continueRequestsAccessibilityThenScreenRecordingThenReady() async {
        let rig = rig()
        await until(rig, .ask)
        #expect(rig.cards.shown == .ask)
        #expect(rig.host.requested.isEmpty, "nothing asks macOS before the person's Continue")
        #expect(rig.setup.remote)
        #expect(rig.setup.pageJSON["grant_holder"] == .string("cmux_remote"))
        #expect(rig.setup.pageJSON["accessibility"] == .bool(false))

        rig.cards.press(ComputerUseRemoteSetupCard.continueButton)
        await until(rig.host, requested: 1)
        #expect(rig.host.requested == [.accessibility])
        #expect(rig.cards.shown == .accessibility)

        rig.cards.press(ComputerUseRemoteSetupCard.openSettingsButton)
        for await opened in ObservationStream({ rig.host.openedSettings }) where !opened.isEmpty { break }
        #expect(rig.host.openedSettings == [.accessibility])

        rig.host.grants.accessibility = true
        rig.distributed.post(name: ComputerUseSetup.accessibilityTrustChanged, object: nil)
        await until(rig.host, requested: 2)
        #expect(rig.host.requested == [.accessibility, .screenRecording])
        #expect(rig.cards.shown == .screenRecording)

        rig.host.grants.screenRecording = true
        rig.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await until(rig, .ready)
        #expect(rig.cards.shown == nil)
        #expect(rig.host.requested == [.accessibility, .screenRecording], "a refresh never asks twice")
        #expect(rig.setup.pageJSON["screen_recording"] == .bool(true))
    }

    /// Already granted (app launch with Computer Use on): no card, no request, ready.
    @Test func grantedIsReadyWithoutACard() async {
        let box = InputBox()
        let host = Host()
        host.grants = ComputerUsePermissions(accessibility: true, screenRecording: true)
        let cards = Cards()
        let setup = ComputerUseSetup(inputs: { box.value }, configuration: { nil }, read: { _ in .noAnswer },
                                     resolveHelper: { _ in nil }, notifications: NotificationCenter(),
                                     distributed: NotificationCenter(), remoteHost: host.remote)
        let flow = ComputerUseRemoteSetupFlow(setup: setup, presenter: cards)
        setup.start()
        flow.start()
        for await step in ObservationStream({ flow.step }) where step == .ready { break }
        #expect(cards.shows == 0)
        #expect(host.requested.isEmpty)
    }

    /// Not Now closes the card and asks nothing; turning Computer Use off and on asks again.
    @Test func notNowAsksNothingUntilComputerUseTurnsOnAgain() async {
        let rig = rig()
        await until(rig, .ask)
        rig.cards.press(ComputerUseRemoteSetupCard.notNowButton)
        #expect(rig.cards.shown == nil)
        rig.setup.recheck()
        #expect(rig.cards.shown == nil)
        #expect(rig.host.requested.isEmpty)

        rig.box.value.enabled = false
        await until(rig, .none)
        rig.box.value.enabled = true
        for await shown in ObservationStream({ rig.cards.shown }) where shown == .ask { break }
        #expect(rig.host.requested.isEmpty)
    }

    /// The legacy driver: setup reads the legacy helper as before, and the flow never shows.
    @Test func theLegacyDriverIsUnchanged() async {
        let rig = rig(.init(disabledByPolicy: false, enabled: true, helper: .off, driver: .legacy, remote: false))
        #expect(!rig.setup.remote)
        #expect(rig.setup.phase == .starting)
        #expect(rig.setup.pageJSON["grant_holder"] == .string("legacy_helper"))
        #expect(rig.flow.step == .none)
        #expect(rig.cards.shows == 0)
        #expect(rig.host.reads == 0, "cmux Remote is never read under the legacy driver")
        // Allow opens the legacy path, never cmux Remote.
        rig.setup.open(.accessibility)
        #expect(rig.host.requested.isEmpty)
    }

    /// The card's copy names both permissions as macOS 27 titles them, with the older names.
    @Test func theCardNamesBothPermissionsAsMacOSShowsThem() {
        let ask = ComputerUseApprovalCards.setupSpec(.ask)
        let text = ([ask.title] + ask.lines).joined(separator: "\n")
        #expect(text.contains("cmux Remote"))
        #expect(text.contains("Device Control and Data Access (Accessibility)"))
        #expect(text.contains("Screen & System Audio Recording (Screen Recording)"))
        #expect(ask.identifier == ComputerUseApprovalService.remoteSetupDialogIdentifier)
        #expect(ask.buttons.map(\.id) == [ComputerUseRemoteSetupCard.notNowButton, ComputerUseRemoteSetupCard.continueButton])
        let ax = ComputerUseApprovalCards.setupSpec(.accessibility)
        #expect(([ax.title] + ax.lines).joined().contains("Device Control and Data Access"))
        let sr = ComputerUseApprovalCards.setupSpec(.screenRecording)
        #expect(([sr.title] + sr.lines).joined().contains("Screen & System Audio Recording"))
    }

    /// The card answers only to the person: automation's `debug.dialog` presses nothing on it.
    @Test func theCardIsUserOnly() {
        #expect(DebugDialog.userOnly.contains(ComputerUseApprovalService.remoteSetupDialogIdentifier))
    }
}
