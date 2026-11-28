public import Foundation

/// Builds the server-side LIST judgment: admit a peer iff the current
/// device-list lease is present and fresh, the TLS-authenticated endpoint is
/// in it, and its entry is not revoked. The hello's grant is ignored
/// entirely (old phones still present one; it carries no authority here).
///
/// The judgment is synchronous and O(1): it reads the atomically swapped
/// ``IrxDeviceListCurrent`` box, never an actor and never the network, so
/// admission latency is unchanged from the grant judge it replaces.
public struct IrxListJudge: Sendable {
    private let current: IrxDeviceListCurrent
    private let journal: IrxJournal
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(
        current: IrxDeviceListCurrent,
        journal: IrxJournal,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.current = current
        self.journal = journal
        self.now = now
    }

    public func judgment() -> IrxGrantJudgment {
        let current = current
        let journal = journal
        let now = now
        return { _, remoteEndpointIDHex in
            let deny: @Sendable (String, IrxCloseCode) -> IrxAdmissionDenied = { reason, code in
                journal.record(
                    "admission", "list-deny",
                    [
                        "reason": reason,
                        "remote": String(remoteEndpointIDHex.prefix(12)),
                    ]
                )
                return IrxAdmissionDenied(code: code)
            }
            guard let snapshot = current.current else {
                throw deny("absent", .invalidGrant)
            }
            guard snapshot.isFresh(now: now()) else {
                throw deny("stale", .invalidGrant)
            }
            guard let entry = snapshot.entries[remoteEndpointIDHex] else {
                throw deny("unknown-endpoint", .invalidGrant)
            }
            if entry.revoked {
                throw deny("revoked", .revoked)
            }
            return IrxAdmittedPeerInfo(
                bindingID: entry.bindingID ?? "",
                deviceID: entry.deviceID ?? remoteEndpointIDHex,
                tag: entry.tag ?? "",
                endpointIDHex: remoteEndpointIDHex,
                identityGeneration: entry.identityGeneration ?? 1
            )
        }
    }
}
