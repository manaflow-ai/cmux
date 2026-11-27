@testable import CmuxNextAgentPermissions
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The card steps aside once Continue hands a computer use request to the
/// Computer Use window, and shows as before for every other grant.
@MainActor @Suite struct PermissionRequestPresenterTests {
    let probe = MockPermissionProbe()
    let opener = RecordingOpener()

    func request(_ kind: PermissionKind) -> PermissionRequest {
        PermissionRequest(kind: kind, reason: "Click Export in Numbers", prompt: "export my sheet",
                          requester: PermissionRequester(agentName: "Claude Code", agentID: "term_a", workspaceName: "Sheets"))
    }

    @Test func theCardHidesWhileTheComputerUseWindowGuides() async throws {
        let requests = AgentPermissionRequests(probe: probe, opener: opener, clock: ManualClock())
        let presenter = PermissionRequestPresenter(requests: requests, appURL: { _ in nil }, guidedElsewhere: { $0.heldByComputerUseHelper })
        let waiting = Task { await requests.request(request(.computerUse), timeout: .seconds(60)) }
        try await until { requests.current != nil }
        #expect(presenter.showsCard(requests.current, granted: nil), "the card asks first")

        requests.continueCurrent()
        try await until { opener.opened == [.accessibility] }
        #expect(!presenter.showsCard(requests.current, granted: nil), "the window guides, not the card")

        probe.set(.accessibility, .granted)
        probe.set(.screenRecording, .granted)
        let outcome = await waiting.value
        #expect(outcome.result == .granted)
        #expect(!presenter.showsCard(requests.current, granted: requests.lastGranted), "the window shows the done state")
    }

    @Test func otherGrantsKeepTheCardGuide() async throws {
        let requests = AgentPermissionRequests(probe: probe, opener: opener, clock: ManualClock())
        let presenter = PermissionRequestPresenter(requests: requests, appURL: { _ in nil }, guidedElsewhere: { $0.heldByComputerUseHelper })
        let waiting = Task { await requests.request(request(.fullDiskAccess), timeout: .seconds(60)) }
        try await until { requests.current != nil }
        requests.continueCurrent()
        try await until { opener.opened == [.fullDiskAccess] }
        #expect(presenter.showsCard(requests.current, granted: nil))
        requests.denyCurrent()
        _ = await waiting.value
    }
}
