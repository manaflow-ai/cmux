public import Foundation

/// One account device as the control plane's directory describes it, keyed by
/// its TLS endpoint identity. The judge consults `revoked` only; the rest is
/// carried for supersession keying (`deviceID`), UI status surfaces
/// (`status`), and diagnostics.
public struct IrxDeviceListEntry: Codable, Equatable, Sendable {
    public var deviceID: String?
    /// Directory lifecycle state: active|seeded|stale|retired|suspended|
    /// pending|superseded. Stored verbatim so new server states pass through.
    public var status: String
    public var revoked: Bool
    public var appVersion: String?
    public var releaseTrack: String?
    public var capabilities: [String]?
    public var relayURLHint: String?
    /// Extra tuple material for the admitted-peer receipt (present when the
    /// directory carries it; admission tolerates absence).
    public var bindingID: String?
    public var tag: String?
    public var identityGeneration: Int?

    public init(
        deviceID: String? = nil,
        status: String,
        revoked: Bool,
        appVersion: String? = nil,
        releaseTrack: String? = nil,
        capabilities: [String]? = nil,
        relayURLHint: String? = nil,
        bindingID: String? = nil,
        tag: String? = nil,
        identityGeneration: Int? = nil
    ) {
        self.deviceID = deviceID
        self.status = status
        self.revoked = revoked
        self.appVersion = appVersion
        self.releaseTrack = releaseTrack
        self.capabilities = capabilities
        self.relayURLHint = relayURLHint
        self.bindingID = bindingID
        self.tag = tag
        self.identityGeneration = identityGeneration
    }
}

/// The authorization lease: the account's device directory at one revision,
/// stamped by the SERVER (`issuedAt` + `ttlSeconds`) and anchored locally to a
/// MONOTONIC receipt instant. Freshness is judged against the monotonic clock
/// so a wall-clock rollback can never revive an expired lease.
public struct IrxDeviceListSnapshot: Equatable, Sendable {
    /// Entries keyed by endpoint ID hex (the TLS-authenticated identity).
    public var entries: [String: IrxDeviceListEntry]
    public var rev: Int
    /// Server stamp: when the server issued this directory fact.
    public var issuedAt: Date
    public var ttlSeconds: Int
    /// Server-advertised minimum Mac version, when available. Kept alongside
    /// the lease so the UI can explain an outdated host after relaunch.
    public var minimumSupportedMacVersion: String?
    /// Wall receipt, persisted so a relaunch can bound the lease.
    public var receivedAtWall: Date
    /// Monotonic receipt, the freshness anchor for this process.
    public var receivedAtMonotonic: ContinuousClock.Instant

    public init(
        entries: [String: IrxDeviceListEntry],
        rev: Int,
        issuedAt: Date,
        ttlSeconds: Int,
        minimumSupportedMacVersion: String? = nil,
        receivedAtWall: Date,
        receivedAtMonotonic: ContinuousClock.Instant
    ) {
        self.entries = entries
        self.rev = rev
        self.issuedAt = issuedAt
        self.ttlSeconds = ttlSeconds
        self.minimumSupportedMacVersion = minimumSupportedMacVersion
        self.receivedAtWall = receivedAtWall
        self.receivedAtMonotonic = receivedAtMonotonic
    }

    /// The lease holds while the MONOTONIC time since receipt is inside the
    /// server-granted TTL. The server stamp anchors the window; the monotonic
    /// anchor makes wall-clock tampering irrelevant in-process.
    public func isFresh(now: ContinuousClock.Instant) -> Bool {
        let elapsed = receivedAtMonotonic.duration(to: now)
        return elapsed >= .zero && elapsed < .seconds(ttlSeconds)
    }

    /// Re-stamps the lease from an explicit server freshness fact (`current`,
    /// or a re-stamped `snapshot_complete`). A freshness frame is not a
    /// directory apply, so it must name the directory we already hold and
    /// carry a strictly newer server stamp. This prevents replayed frames from
    /// extending a revoked or dropped entry's authorization lease.
    public func restamped(
        rev: Int,
        issuedAt: Date,
        receivedAtWall: Date,
        receivedAtMonotonic: ContinuousClock.Instant
    ) -> IrxDeviceListSnapshot? {
        guard rev == self.rev, issuedAt > self.issuedAt else { return nil }
        var updated = self
        updated.rev = rev
        updated.issuedAt = issuedAt
        updated.receivedAtWall = receivedAtWall
        updated.receivedAtMonotonic = receivedAtMonotonic
        return updated
    }
}

/// The synchronously readable CURRENT snapshot the accept path judges against.
/// Admission must be O(1) with no actor hop (the judge closure runs inside
/// `IrxAdmission.performServer`), so this is a lock-guarded box the runtime
/// swaps atomically on every directory apply and clears on sign-out.
public final class IrxDeviceListCurrent: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: IrxDeviceListSnapshot?

    public init() {}

    public var current: IrxDeviceListSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func replace(_ next: IrxDeviceListSnapshot?) {
        lock.lock()
        snapshot = next
        lock.unlock()
    }

    /// Fails closed instantly: with no snapshot, the judge denies everything.
    public func clear() {
        replace(nil)
    }

    /// Applies a freshness re-stamp to the held snapshot, returning the
    /// updated value (for persistence) or nil when there is nothing to stamp
    /// or the stamp is older than what is held.
    @discardableResult
    public func restamp(
        rev: Int,
        issuedAt: Date,
        receivedAtWall: Date,
        receivedAtMonotonic: ContinuousClock.Instant
    ) -> IrxDeviceListSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let updated = snapshot?.restamped(
                rev: rev,
                issuedAt: issuedAt,
                receivedAtWall: receivedAtWall,
                receivedAtMonotonic: receivedAtMonotonic
            )
        else { return nil }
        snapshot = updated
        return updated
    }
}

extension IrxDeviceListSnapshot {
    /// Default lease when a pre-list-auth server omits the stamp: one day,
    /// mirroring the contract's `ttlSeconds` default.
    public static let defaultTTLSeconds = 86_400

    /// Builds the snapshot from a decoded directory fact. Entries default to
    /// `status: "active"`, `revoked: false` when a pre-upgrade server omits
    /// the fields: presence in the account directory IS the authorization
    /// set, so the defensive default keeps such accounts connectable.
    public init(
        fact: IrxCtlDirectoryFact,
        receivedAtWall: Date,
        receivedAtMonotonic: ContinuousClock.Instant
    ) {
        var entries: [String: IrxDeviceListEntry] = [:]
        for binding in fact.payload.bindings {
            entries[binding.endpointID] = IrxDeviceListEntry(
                deviceID: binding.deviceID,
                status: binding.status ?? "active",
                revoked: binding.revoked ?? false,
                appVersion: binding.appVersion,
                releaseTrack: binding.releaseTrack,
                capabilities: binding.capabilities,
                relayURLHint: binding.homeRelayURL,
                bindingID: binding.bindingID,
                tag: binding.instanceTag,
                identityGeneration: binding.identityGeneration
            )
        }
        self.init(
            entries: entries,
            rev: fact.rev,
            issuedAt: fact.payload.issuedAt ?? receivedAtWall,
            ttlSeconds: fact.payload.ttlSeconds ?? Self.defaultTTLSeconds,
            minimumSupportedMacVersion: fact.payload.minimumSupportedVersion?.mac,
            receivedAtWall: receivedAtWall,
            receivedAtMonotonic: receivedAtMonotonic
        )
    }
}
