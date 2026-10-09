/// Authorizes a fixed set of device keys (tests, a single paired phone).
public struct WebRTCPinnedAuthorizer: WebRTCAuthorizer {
    public var devices: Set<WebRTCPublicKey>

    public init(devices: Set<WebRTCPublicKey>) {
        self.devices = devices
    }

    public func authorize(device: WebRTCPublicKey, install: String?) async -> Bool {
        devices.contains(device)
    }
}
