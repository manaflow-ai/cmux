public import Foundation

/// The immutable backend and identity scope for one control-service instance.
public struct V2ControlConfiguration: Sendable {
    /// Cloudflare origin selected by the build environment.
    public let baseURL: URL
    /// This device's newly generated v2 identity and initial metadata.
    public let device: V2DeviceDescriptor
    /// Individual request deadline, independent of receive-idle time.
    public let requestTimeout: TimeInterval
    /// Maximum operations waiting for replies on one client.
    public let maximumPendingRequests: Int

    /// Creates a control owner for one full identity scope.
    /// - Parameters:
    ///   - baseURL: Explicit HTTPS Cloudflare origin, with HTTP permitted for loopback testing.
    ///   - device: The identity whose key the signing dependency uses.
    ///   - requestTimeout: A bounded operation deadline, defaulting to 30 seconds.
    ///   - maximumPendingRequests: A finite client-side buffer, defaulting to 256 operations.
    /// - Throws: A scope error for an insecure non-loopback origin or disabled Mac pairing.
    public init(baseURL: URL, device: V2DeviceDescriptor, requestTimeout: TimeInterval = 30, maximumPendingRequests: Int = 256) throws {
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(baseURL.host ?? "")
        guard baseURL.scheme == "https" || (baseURL.scheme == "http" && loopback),
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              device.metadata.platform != .mac || device.metadata.pairingEnabled else {
            throw V2ControlFailure.scopeMismatch
        }
        self.baseURL = baseURL
        self.device = device
        self.requestTimeout = max(1, requestTimeout)
        self.maximumPendingRequests = max(1, maximumPendingRequests)
    }
}
