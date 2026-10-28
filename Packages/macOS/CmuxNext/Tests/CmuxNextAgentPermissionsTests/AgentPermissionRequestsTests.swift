@testable import CmuxNextAgentPermissions
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// The request store (agent-permissions-DESIGN.md section 2) against a mock
/// TCC probe: no card for a grant that is on, nothing opens before Continue,
/// Deny returns `denied`, the grant landing returns `granted`, computer use
/// guides through both grants, duplicates join, others queue, timeouts end.
@MainActor @Suite struct AgentPermissionRequestsTests {
    let probe = MockPermissionProbe()
    let opener = RecordingOpener()
    let clock = ManualClock()

    func makeRequests() -> AgentPermissionRequests {
        var next = 0
        return AgentPermissionRequests(probe: probe, opener: opener, clock: clock, makeID: { next += 1; return "perm_\(next)" })
    }

    func request(_ kind: PermissionKind, agent: String = "term_a", reason: String = "Read Mail to find the invoices",
                 prompt: String? = "find my invoices in mail") -> PermissionRequest {
        PermissionRequest(kind: kind, reason: reason, prompt: prompt,
                          requester: PermissionRequester(agentName: "Claude Code", agentID: agent, workspaceName: "Invoices"))
    }

    @Test func aGrantThatIsOnAnswersWithoutACard() async {
        probe.set(.fullDiskAccess, .granted)
        let requests = makeRequests()
        let outcome = await requests.request(request(.fullDiskAccess), timeout: .seconds(60))
        #expect(outcome.result == .alreadyGranted)
        #expect(outcome.requestID == nil)
        #expect(requests.current == nil)
        #expect(opener.opened.isEmpty)
    }

    @Test func nothingOpensBeforeContinueAndDenyReturnsDenied() async throws {
        let requests = makeRequests()
        let waiting = Task { await requests.request(request(.fullDiskAccess), timeout: .seconds(60)) }
        try await until { requests.current != nil }
        let shown = try #require(requests.current)
        #expect(shown.phase == .asking)
        #expect(shown.request.requester.agentName == "Claude Code")
        #expect(shown.reasonCheck == .matches)
        #expect(opener.opened.isEmpty, "System Settings opened before the person pressed Continue")

        requests.denyCurrent()
        let outcome = await waiting.value
        #expect(outcome.result == .denied)
        #expect(outcome.result.errorCode == "permission_denied")
        #expect(outcome.requestID == "perm_1")
        #expect(requests.current == nil)
        #expect(opener.opened.isEmpty)
    }

    @Test func continueOpensTheListAndTheGrantLandingReturnsGranted() async throws {
        let requests = makeRequests()
        let waiting = Task { await requests.request(request(.fullDiskAccess), timeout: .seconds(60)) }
        try await until { requests.current != nil }
        requests.continueCurrent()
        try await until { opener.opened == [.fullDiskAccess] }
        #expect(requests.current?.phase == .guiding)
        #expect(requests.current?.guidingGrant == .fullDiskAccess)

        probe.set(.fullDiskAccess, .granted)
        let outcome = await waiting.value
        #expect(outcome.result == .granted)
        #expect(outcome.result.errorCode == nil)
        #expect(requests.current == nil)
        #expect(requests.lastGranted?.id == "perm_1")
    }

    @Test func computerUseGuidesThroughBothGrantsInTurn() async throws {
        let requests = makeRequests()
        let waiting = Task {
            await requests.request(request(.computerUse, reason: "Click Export in Numbers", prompt: "export from Numbers"),
                                   timeout: .seconds(60))
        }
        try await until { requests.current != nil }
        requests.continueCurrent()
        try await until { opener.opened == [.accessibility] }
        probe.set(.accessibility, .granted)
        try await until { opener.opened == [.accessibility, .screenRecording] }
        #expect(requests.current?.guidingGrant == .screenRecording)
        probe.set(.screenRecording, .granted)
        let outcome = await waiting.value
        #expect(outcome.result == .granted)
        #expect(outcome.kind == .computerUse)
    }

    @Test func theSameGrantFromTheSameAgentJoinsOneCard() async throws {
        let requests = makeRequests()
        let first = Task { await requests.request(request(.fullDiskAccess), timeout: .seconds(60)) }
        try await until { requests.current != nil }
        let second = Task { await requests.request(request(.fullDiskAccess), timeout: .seconds(60)) }
        try await until { requests.current?.callers == 2 }
        #expect(requests.queued.isEmpty)
        requests.denyCurrent()
        #expect(await first.value.result == .denied)
        #expect(await second.value.result == .denied)
        #expect(await first.value.requestID == second.value.requestID)
    }

    @Test func otherRequestsQueueAndShowInTurn() async throws {
        let requests = makeRequests()
        let first = Task { await requests.request(request(.fullDiskAccess), timeout: .seconds(60)) }
        try await until { requests.current != nil }
        let second = Task { await requests.request(request(.camera, agent: "term_b", reason: "Scan the QR code", prompt: "scan this QR"),
                                                   timeout: .seconds(60)) }
        try await until { requests.queued.count == 1 }
        #expect(requests.current?.request.kind == .fullDiskAccess)
        requests.denyCurrent()
        #expect(await first.value.result == .denied)
        #expect(requests.current?.request.kind == .camera)
        #expect(requests.current?.phase == .asking)
        requests.cancel("perm_2")
        #expect(await second.value.result == .cancelled)
        #expect(requests.current == nil)
    }

    @Test func aRequestNobodyAnswersTimesOut() async throws {
        let requests = makeRequests()
        let waiting = Task { await requests.request(request(.microphone, reason: "Record your voice note", prompt: "record a voice note"),
                                                    timeout: .seconds(300)) }
        try await until { requests.current != nil }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(299))
        #expect(requests.current != nil)
        clock.advance(by: .seconds(1))
        let outcome = await waiting.value
        #expect(outcome.result == .timedOut)
        #expect(outcome.result.errorCode == "permission_timed_out")
        #expect(requests.current == nil)
    }

    @Test func anUnclearReasonIsFlaggedOnTheCard() async throws {
        let requests = makeRequests()
        let waiting = Task {
            await requests.request(request(.fullDiskAccess, reason: "Scan the whole system for keys", prompt: "rename the sidebar groups"),
                                   timeout: .seconds(60))
        }
        try await until { requests.current != nil }
        #expect(requests.current?.reasonCheck == .unclear)
        requests.denyCurrent()
        #expect(await waiting.value.reasonCheck == .unclear)
    }
}

/// Records which lists the store opened.
@MainActor final class RecordingOpener: PermissionSettingsOpening {
    private(set) var opened: [PermissionKind] = []
    func open(_ kind: PermissionKind, target: String?) { opened.append(kind) }
}

/// Waits (bounded) for main-actor state the store sets after a hop.
@MainActor func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<2000 where !condition() { await Task.yield() }
    try #require(condition(), "condition never held", sourceLocation: sourceLocation)
}
