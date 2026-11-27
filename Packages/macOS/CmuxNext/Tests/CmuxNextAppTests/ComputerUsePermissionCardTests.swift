import CmuxNextAgentActivity
import CmuxNextAgentPermissions
import CmuxNextCompat
@testable import CmuxNextOnboarding
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// The agent card's Continue (AgentPermissionRequests through
/// SystemPermissionOpener) is the main way a person sets up computer use: it
/// shows the Computer Use window. On macOS 26 the Screen Recording toggle
/// alone leaves the helper's capture check false until the helper asks once,
/// so Allow in that window sends `request_system_permission`
/// (`AppComputerUsePermissionSource.openSettings`, `ComputerUseSetup.open`). Before, the card never ended `granted`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComputerUsePermissionCardTests {
    private nonisolated struct RetryClock: Clock {
        typealias Instant = ContinuousClock.Instant
        var now: Instant { ContinuousClock.now }
        var minimumResolution: Duration { .nanoseconds(1) }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try Task.checkCancellation()
        }
    }

    private struct Card {
        let setup: ComputerUseSetup
        let requests: AgentPermissionRequests
        let grants: ComputerUseSetupTests.GrantRequests
        let opened: OpenedURLs
    }

    @MainActor @Observable final class OpenedURLs {
        var urls: [URL] = []
        /// How many times Continue showed the Computer Use window.
        var windows = 0
    }

    /// A ready legacy helper with `granted` grants, and the card store the App builds over it.
    private func makeCard(_ granted: ComputerUsePermissions) async -> Card {
        let grants = ComputerUseSetupTests.GrantRequests()
        let opened = OpenedURLs()
        let setup = ComputerUseSetup(
            inputs: { ComputerUseSetup.Inputs(disabledByPolicy: false, enabled: true, helper: .running(42)) },
            configuration: { .init(socketPath: "/unused/cua.sock", authToken: "a", hostAuthToken: "h", machineName: "") },
            read: { _ in .answered(granted, helper: nil) },
            resolveHelper: { _ in nil },
            openURL: { opened.urls.append($0) },
            requestGrant: { _, pane in await grants.add(pane) },
            notifications: NotificationCenter(), distributed: NotificationCenter(), clock: RetryClock())
        setup.start()
        for await phase in ObservationStream({ setup.phase }) where phase == .ready { break }
        let probe = SystemPermissionProbe(setup: setup, notifications: NotificationCenter(), distributed: NotificationCenter())
        let opener = SystemPermissionOpener(setup: setup, showComputerUse: { opened.windows += 1 },
                                            openURL: { opened.urls.append($0) })
        let requests = AgentPermissionRequests(probe: probe, opener: opener)
        return Card(setup: setup, requests: requests, grants: grants, opened: opened)
    }

    private func computerUseRequest() -> PermissionRequest {
        PermissionRequest(kind: .computerUse, reason: "Click Export in Numbers", prompt: "export from Numbers",
                          requester: PermissionRequester(agentName: "Claude Code", agentID: "term_a"))
    }

    @Test func continueShowsTheWindowAndScreenshotsAllowAsksTheHelperOnce() async throws {
        let card = await makeCard(ComputerUsePermissions(accessibility: true, screenRecording: false))
        let waiting = Task { await card.requests.request(computerUseRequest(), timeout: .seconds(60)) }
        for await shown in ObservationStream({ card.requests.current != nil }) where shown { break }
        card.requests.continueCurrent()
        for await windows in ObservationStream({ card.opened.windows }) where windows >= 1 { break }
        #expect(card.opened.windows == 1)
        #expect(card.opened.urls.isEmpty)
        // Allow on Screenshots in the window.
        AppComputerUsePermissionSource(setup: card.setup).openSettings(.screenRecording)
        for await count in ObservationStream({ card.grants.count }) where count >= 1 { break }
        #expect(await card.grants.panes == [.screenRecording])
        #expect(card.opened.urls == [ComputerUseSetup.settingsURL(.screenRecording)])
        card.requests.denyCurrent()
        _ = await waiting.value
    }

    /// Accessibility needs only the toggle: the request would raise macOS's
    /// "would like to control this computer" alert over the drag panel.
    @Test func accessibilityAllowAfterContinueSendsNoRequest() async throws {
        let card = await makeCard(ComputerUsePermissions(accessibility: false, screenRecording: false))
        let waiting = Task { await card.requests.request(computerUseRequest(), timeout: .seconds(60)) }
        for await shown in ObservationStream({ card.requests.current != nil }) where shown { break }
        card.requests.continueCurrent()
        for await windows in ObservationStream({ card.opened.windows }) where windows >= 1 { break }
        #expect(card.opened.windows == 1)
        // Allow on Accessibility in the window.
        AppComputerUsePermissionSource(setup: card.setup).openSettings(.accessibility)
        for await count in ObservationStream({ card.opened.urls.count }) where count >= 1 { break }
        #expect(card.opened.urls == [ComputerUseSetup.settingsURL(.accessibility)])
        card.requests.denyCurrent()
        _ = await waiting.value
        #expect(await card.grants.panes.isEmpty)
    }
}
