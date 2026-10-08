import CmuxWindowing
import Foundation
import Testing

@Suite("Single-instance replacement lease")
struct SingleInstanceReplacementLeaseTests {
    private let bundle = URL(fileURLWithPath: "/Applications/cmux.app", isDirectory: true)

    @Test("a fresh lease authorizes only its process and bundle")
    func freshLeaseIsBound() {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let lease = SingleInstanceReplacementLease(
            bundleURL: bundle,
            processIdentifier: 42,
            issuedAt: issuedAt
        )

        #expect(
            lease.authorizes(bundleURL: bundle, processIdentifier: 42, now: issuedAt.addingTimeInterval(1))
        )
        #expect(
            !lease.authorizes(bundleURL: bundle, processIdentifier: 43, now: issuedAt.addingTimeInterval(1))
        )
        #expect(
            !lease.authorizes(
                bundleURL: URL(fileURLWithPath: "/Applications/other.app"),
                processIdentifier: 42,
                now: issuedAt.addingTimeInterval(1)
            )
        )
    }

    @Test("an expired or future lease does not authorize replacement")
    func staleLeaseRejected() {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let lease = SingleInstanceReplacementLease(bundleURL: bundle, processIdentifier: 42, issuedAt: issuedAt)

        #expect(
            !lease.authorizes(bundleURL: bundle, processIdentifier: 42, now: issuedAt.addingTimeInterval(-1))
        )
        #expect(
            !lease.authorizes(
                bundleURL: bundle,
                processIdentifier: 42,
                now: issuedAt.addingTimeInterval(SingleInstanceReplacementLease.maxAge + 1)
            )
        )
    }
}
