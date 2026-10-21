import CmuxNextRemote
import Foundation
import Testing

@Suite
struct RemoteHostVisibilityProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func receipt(
        machineID: String = "ssh-huge-blue",
        attemptID: String = "attempt-1",
        acceptedAt: Date? = nil
    ) -> RemoteHostVisibilityProjection.RegistrationReceipt {
        .init(machineID: machineID, attemptID: attemptID, hostID: "host-huge-blue",
              acceptedAt: acceptedAt ?? now)
    }

    @Test func a403IsBlockedWithAnMFAReason() {
        let projection = RemoteHostVisibilityProjection.make(
            hostLabel: "Huge Blue", machineID: "ssh-huge-blue", ssh: .connected,
            evidence: .rejected(statusCode: 403, message: "Multi-factor authentication required", occurredAt: now),
            now: now
        )

        #expect(projection.registration == .blocked(reason: .mfaRequired(
            statusCode: 403, message: "Multi-factor authentication required")))
        #expect(projection.ssh == .connected)
        #expect(projection.accessibleLabel.contains("SSH connected"))
        #expect(projection.accessibleLabel.contains("MFA required"))
    }

    @Test func retryIsPendingWithoutPretendingItIsEnrolled() {
        let projection = RemoteHostVisibilityProjection.make(
            hostLabel: "Huge Blue", machineID: "ssh-huge-blue", ssh: .connected,
            expectedAttemptID: "attempt-2",
            evidence: .pending(attemptID: "attempt-2", startedAt: now),
            now: now
        )

        #expect(projection.registration == .pending(attemptID: "attempt-2"))
        #expect(projection.registration.accessibleLabel == "Codex Desktop enrollment pending")
    }

    @Test func onlyAnExactCurrentReceiptCanBecomeEnrolled() {
        let projection = RemoteHostVisibilityProjection.make(
            hostLabel: "Huge Blue", machineID: "ssh-huge-blue", ssh: .connected,
            expectedAttemptID: "attempt-1", evidence: .accepted(receipt()), now: now
        )
        #expect(projection.registration == .enrolled(receipt()))

        let wrongAttempt = RemoteHostVisibilityProjection.make(
            hostLabel: "Huge Blue", machineID: "ssh-huge-blue", ssh: .connected,
            expectedAttemptID: "attempt-2", evidence: .accepted(receipt()), now: now
        )
        #expect(wrongAttempt.registration == .blocked(reason: .invalidReceipt))

        let wrongMachine = RemoteHostVisibilityProjection.make(
            hostLabel: "Huge Blue", machineID: "ssh-huge-blue", ssh: .connected,
            evidence: .accepted(receipt(machineID: "ssh-other")), now: now
        )
        #expect(wrongMachine.registration == .blocked(reason: .invalidReceipt))
    }

    @Test func anOldReceiptIsStale() {
        let old = receipt(acceptedAt: now.addingTimeInterval(-901))
        let projection = RemoteHostVisibilityProjection.make(
            hostLabel: "Huge Blue", machineID: "ssh-huge-blue", ssh: .connected,
            evidence: .accepted(old), now: now, staleAfter: 900
        )

        #expect(projection.registration == .stale(old))
        #expect(projection.registration.accessibleLabel == "Codex Desktop enrollment stale")
    }

    @Test func unknownOrUnlinkedHostsNeverClaimEnrollment() {
        let projection = RemoteHostVisibilityProjection.make(
            hostLabel: "Unknown host", machineID: nil, ssh: .connected,
            evidence: .accepted(receipt()), now: now
        )

        #expect(projection.registration == .blocked(reason: .unlinked))
        #expect(projection.accessibleLabel == "Unknown host, SSH connected, Codex Desktop enrollment unavailable: host is not linked")
    }

    @Test func sshStatusMapsToDistinctAccessibleLabels() {
        #expect(RemoteHostVisibilityProjection.sshState(.connected).accessibleLabel == "SSH connected")
        #expect(RemoteHostVisibilityProjection.sshState(.reconnecting).accessibleLabel == "SSH reconnecting")
        #expect(RemoteHostVisibilityProjection.sshState(.authFailed("denied")).accessibleLabel == "SSH failed: denied")
    }
}
