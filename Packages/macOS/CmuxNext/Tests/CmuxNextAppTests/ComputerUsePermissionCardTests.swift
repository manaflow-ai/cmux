import CmuxNextAgentActivity
import CmuxNextAgentPermissions
import CmuxNextCompat
@testable import CmuxNextOnboarding
import CmuxNextWakeups
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// The agent card's Continue (AgentPermissionRequests through
/// SystemPermissionOpener) is the main way a person sets up computer use. On
/// macOS 26 the Screen Recording toggle alone leaves the helper's capture
/// check false until the helper asks once, so Continue must send the same
/// `request_system_permission` as Allow in Settings and onboarding
/// (`ComputerUseSetup.open`). Before, it only opened System Settings, and the
/// card never ended `granted`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComputerUsePermissionCardTests {
    private struct Card {
        let rig: MainDeadlineRig
        let setup: ComputerUseSetup
        let requests: AgentPermissionRequests
        let grants: ComputerUseSetupTests.GrantRequests
        let opened: OpenedURLs
    }

    @MainActor @Observable final class OpenedURLs {
        var urls: [URL] = []
    }

    /// A ready legacy helper with `granted` grants, and the card store the App builds over it.
    private func makeCard(_ granted: ComputerUsePermissions) async -> Card {
        let grants = ComputerUseSetupTests.GrantRequests()
        let opened = OpenedURLs()
        let rig = MainDeadlineRig()
        let setup = ComputerUseSetup(
            inputs: { ComputerUseSetup.Inputs(disabledByPolicy: false, enabled: true, helper: .running(42)) },
            configuration: { .init(socketPath: "/unused/cua.sock", authToken: "a", hostAuthToken: "h", machineName: "") },
            read: { _ in .answered(granted, helper: nil) },
            resolveHelper: { _ in nil },
            openURL: { opened.urls.append($0) },
            requestGrant: { _, pane in await grants.add(pane) },
            appEvents: AppEvents(center: NotificationCenter()), distributedEvents: AppEvents(center: NotificationCenter()),
            deadlines: rig.deadlines, work: BackgroundWork())
        setup.start()
        await ComputerUseSetupTests.run(rig) { setup.phase == .ready }
        let probe = SystemPermissionProbe(setup: setup, appEvents: AppEvents(center: NotificationCenter()), mainWork: rig.work)
        let requests = AgentPermissionRequests(probe: probe, opener: SystemPermissionOpener(setup: setup, work: BackgroundWork()))
        return Card(rig: rig, setup: setup, requests: requests, grants: grants, opened: opened)
    }

    private func computerUseRequest() -> PermissionRequest {
        PermissionRequest(kind: .computerUse, reason: "Click Export in Numbers", prompt: "export from Numbers",
                          requester: PermissionRequester(agentName: "Claude Code", agentID: "term_a"))
    }

    @Test func continueWithScreenRecordingMissingAsksTheHelperOnce() async throws {
        let card = await makeCard(ComputerUsePermissions(accessibility: true, screenRecording: false))
        let waiting = Task { await card.requests.request(computerUseRequest(), timeout: .seconds(60)) }
        await ComputerUseSetupTests.run(card.rig) { card.requests.current != nil }
        card.requests.continueCurrent()
        await ComputerUseSetupTests.run(card.rig) { card.grants.count >= 1 }
        #expect(await card.grants.panes == [.screenRecording])
        #expect(card.opened.urls == [ComputerUseSetup.settingsURL(.screenRecording)])
        card.requests.denyCurrent()
        _ = await waiting.value
    }

    /// Accessibility needs only the toggle: the request would raise macOS's
    /// "would like to control this computer" alert over the drag panel.
    @Test func continueWithAccessibilityMissingSendsNoRequest() async throws {
        let card = await makeCard(ComputerUsePermissions(accessibility: false, screenRecording: false))
        let waiting = Task { await card.requests.request(computerUseRequest(), timeout: .seconds(60)) }
        await ComputerUseSetupTests.run(card.rig) { card.requests.current != nil }
        card.requests.continueCurrent()
        await ComputerUseSetupTests.run(card.rig) { card.opened.urls.count >= 1 }
        #expect(card.opened.urls == [ComputerUseSetup.settingsURL(.accessibility)])
        card.requests.denyCurrent()
        _ = await waiting.value
        #expect(await card.grants.panes.isEmpty)
    }
}
