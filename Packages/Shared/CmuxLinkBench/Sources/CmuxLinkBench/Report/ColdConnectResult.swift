/// Fresh endpoints per sample: `connect()` to a live path, and to the first
/// echoed byte on a newly opened channel (what a user waits for).
public struct ColdConnectResult: Codable, Sendable {
    public var connectToLive: Distribution
    public var firstByte: Distribution
    /// In run order; the first includes one-time process setup (libwebrtc factory, Network.framework).
    public var firstByteSamples: [Double]
}
