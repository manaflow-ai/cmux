public import CMUXMobileCore

/// Stable identity for the sole process-local session owner of one remote device.
public struct CmxConnectivityPeerID: Hashable, Sendable {
    /// QUIC TLS identity of the remote endpoint.
    public let identity: CmxIrohPeerIdentity

    /// Authenticated cmux device identifier expected after admission.
    public let deviceID: String

    /// Creates a canonical peer identity.
    public init(identity: CmxIrohPeerIdentity, deviceID: String) {
        self.identity = identity
        self.deviceID = cmxCanonicalDeviceID(deviceID)
    }

    init(request: CmxByteTransportRequest) throws {
        guard request.authorizationMode == .transportAdmission,
              let expectedDeviceID = request.expectedPeerDeviceID,
              !expectedDeviceID.isEmpty,
              case let .peer(identity, _) = request.route.endpoint else {
            throw CmxConnectivityEngineError.invalidPeerIntent
        }
        self.init(identity: identity, deviceID: expectedDeviceID)
    }
}
