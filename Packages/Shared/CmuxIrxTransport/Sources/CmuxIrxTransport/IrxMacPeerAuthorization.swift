public import CmuxIrohTransport

/// The exact remote Mac selected by a person or an account discovery row.
public struct IrxMacPeerAuthorization: Sendable {
    /// A failed binding check, kept distinct from a temporarily unavailable directory.
    public enum Failure: Error, Equatable, Sendable {
        /// The host has no active, discoverable binding yet.
        case unavailable
        /// No fresh authenticated device-list lease is available.
        case staleDirectory
        /// The device list revoked the endpoint.
        case revoked
        /// The proposed endpoint belongs to another device or build.
        case identityMismatch
    }

    /// The expected physical Mac UUID.
    public let deviceID: String
    /// The expected release channel or dev tag.
    public let tag: String
    /// The exact TLS peer identity, never a fallback destination.
    public let endpointID: String

    /// Creates immutable intent for one device, build, and endpoint.
    public init(deviceID: String, tag: String, endpointID: String) {
        self.deviceID = deviceID.lowercased()
        self.tag = tag
        self.endpointID = endpointID
    }

    /// Resolves only from an authenticated broker response and fresh account lease.
    /// Legacy leases may omit the identity generation; the broker's complete tuple
    /// remains authoritative and the unique binding ID must still match.
    ///
    /// - Parameters:
    ///   - bindings: Bindings from this account's authenticated broker request.
    ///   - lease: The same account's current device-list lease.
    ///   - localDeviceID: The caller's physical device, excluded from remote control.
    ///   - now: Monotonic time used to check lease expiration.
    /// - Returns: The exact, enabled Mac binding.
    /// - Throws: ``Failure`` when the intended peer cannot be authorized.
    public func resolve(
        bindings: [CmxIrohBrokerBinding],
        lease: IrxDeviceListSnapshot?,
        localDeviceID: String,
        now: ContinuousClock.Instant = .now
    ) throws -> CmxIrohBrokerBinding {
        let matches = bindings.filter { $0.endpointID.endpointID == endpointID }
        guard !matches.isEmpty else { throw Failure.unavailable }
        guard matches.count == 1, let binding = matches.first,
              binding.deviceID == deviceID, binding.tag == tag,
              binding.platform == .mac, binding.deviceID != localDeviceID.lowercased() else {
            throw Failure.identityMismatch
        }
        guard binding.pairingEnabled else { throw Failure.unavailable }
        guard let lease, lease.isFresh(now: now) else { throw Failure.staleDirectory }
        guard let entry = lease.entries[endpointID] else { throw Failure.staleDirectory }
        guard !entry.revoked else { throw Failure.revoked }
        guard entry.deviceID == deviceID, entry.tag == tag,
              entry.bindingID == binding.bindingID else { throw Failure.identityMismatch }
        if let generation = entry.identityGeneration, generation != binding.identityGeneration {
            throw Failure.identityMismatch
        }
        return binding
    }
}
