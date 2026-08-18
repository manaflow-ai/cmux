import Foundation
import Testing

@testable import CmuxPeerTransportCore

private final class VerdictScript: @unchecked Sendable {
    private let lock = NSLock()
    private var verdicts: [PeerBrokerAdmissionVerdict]
    private(set) var callCount = 0

    init(_ verdicts: [PeerBrokerAdmissionVerdict]) {
        self.verdicts = verdicts
    }

    func next() -> PeerBrokerAdmissionVerdict {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        guard !verdicts.isEmpty else { return .unreachable }
        return verdicts.count == 1 ? verdicts[0] : verdicts.removeFirst()
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

private enum AdmissionHarness {
    static let endpointID = "ab12cd34"

    static func grant(
        id: String = "grant-1",
        endpointID: String = AdmissionHarness.endpointID,
        expiresIn: TimeInterval = 3600
    ) -> PeerVerifiedGrant {
        PeerVerifiedGrant(
            grantID: id,
            initiatorDeviceID: "phone-device",
            acceptorDeviceID: "mac-device",
            initiatorEndpointID: endpointID,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    static func controller(
        grant: PeerVerifiedGrant,
        script: VerdictScript,
        revalidationInterval: Duration = .seconds(30)
    ) -> PeerAdmissionController {
        PeerAdmissionController(
            configuration: .init(revalidationInterval: revalidationInterval),
            verifyGrant: { credential in
                guard credential == "valid" else {
                    struct Invalid: Error {}
                    throw Invalid()
                }
                return grant
            },
            brokerVerdict: { _ in script.next() }
        )
    }
}

@Suite struct PeerAdmissionControllerTests {
    @Test func admitsVerifiedGrantWithOnlineBrokerApproval() async {
        let grant = AdmissionHarness.grant()
        let script = VerdictScript([.admitted])
        let controller = AdmissionHarness.controller(grant: grant, script: script)

        let decision = await controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        #expect(decision == .admitted(grant))
    }

    @Test func deniesInvalidCredentialWithoutBrokerCall() async {
        let grant = AdmissionHarness.grant()
        let script = VerdictScript([.admitted])
        let controller = AdmissionHarness.controller(grant: grant, script: script)

        let decision = await controller.admit(
            credential: "garbage",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        #expect(decision == .denied(reason: "invalid-grant"))
        #expect(script.calls == 0)
    }

    @Test func deniesGrantBoundToADifferentEndpoint() async {
        let grant = AdmissionHarness.grant()
        let script = VerdictScript([.admitted])
        let controller = AdmissionHarness.controller(grant: grant, script: script)

        let decision = await controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: "ffffffff"
        )
        #expect(decision == .denied(reason: "endpoint-mismatch"))
        #expect(script.calls == 0)
    }

    @Test func deniesExpiredGrantLocally() async {
        let grant = AdmissionHarness.grant(expiresIn: -10)
        let script = VerdictScript([.admitted])
        let controller = AdmissionHarness.controller(grant: grant, script: script)

        let decision = await controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        #expect(decision == .denied(reason: "expired-grant"))
        #expect(script.calls == 0)
    }

    @Test func brokerConnectivityFailurePermitsOfflineAdmission() async {
        let grant = AdmissionHarness.grant()
        let script = VerdictScript([.unreachable])
        let controller = AdmissionHarness.controller(grant: grant, script: script)

        let decision = await controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        #expect(decision == .admitted(grant))
    }

    @Test func onlineDenialIsStickyAgainstLaterConnectivityFailure() async {
        let grant = AdmissionHarness.grant()
        let script = VerdictScript([.denied("revoked"), .unreachable])
        let controller = AdmissionHarness.controller(
            grant: grant,
            script: script,
            revalidationInterval: .milliseconds(1)
        )

        let first = await controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        #expect(first == .denied(reason: "revoked"))

        // A later broker outage must not restore access.
        try? await ContinuousClock().sleep(for: .milliseconds(5))
        let second = await controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        #expect(second == .denied(reason: "denied-sticky"))
    }

    @Test func concurrentAdmissionsShareOneBrokerSnapshot() async {
        let grant = AdmissionHarness.grant()
        let script = VerdictScript([.admitted])
        let controller = AdmissionHarness.controller(grant: grant, script: script)

        async let a = controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        async let b = controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        _ = await (a, b)
        // The second admission reuses the cached verdict within the interval.
        #expect(script.calls == 1)
    }

    @Test func monitorClosesOnConfirmedRevoke() async {
        let grant = AdmissionHarness.grant()
        let script = VerdictScript([.admitted, .denied("revoked")])
        let controller = AdmissionHarness.controller(
            grant: grant,
            script: script,
            revalidationInterval: .milliseconds(5)
        )

        _ = await controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        let reason = await controller.revalidationMonitor(grant: grant)
        #expect(reason == .revoked)
    }

    @Test func monitorSurvivesConnectivityFailures() async {
        let grant = AdmissionHarness.grant()
        let script = VerdictScript([
            .admitted, .unreachable, .unreachable, .denied("revoked"),
        ])
        let controller = AdmissionHarness.controller(
            grant: grant,
            script: script,
            revalidationInterval: .milliseconds(5)
        )

        _ = await controller.admit(
            credential: "valid",
            expectedInitiatorEndpointID: AdmissionHarness.endpointID
        )
        let reason = await controller.revalidationMonitor(grant: grant)
        // Two outages preserved the session; the confirmed revoke closed it.
        #expect(reason == .revoked)
        #expect(script.calls >= 4)
    }

    @Test func monitorClosesAtGrantExpiryEvenWhenIdle() async {
        let grant = AdmissionHarness.grant(expiresIn: 0.05)
        let script = VerdictScript([.admitted])
        let controller = AdmissionHarness.controller(
            grant: grant,
            script: script,
            revalidationInterval: .seconds(30)
        )

        let reason = await controller.revalidationMonitor(grant: grant)
        #expect(reason == .local("grant-expired"))
    }
}
