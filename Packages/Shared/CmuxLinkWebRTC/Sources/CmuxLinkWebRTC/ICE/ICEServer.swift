/// One STUN or TURN server entry (`signal.turn_credentials:result`).
public struct ICEServer: Sendable, Hashable {
    /// `stun:`, `turn:` or `turns:` URLs.
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    /// Whether any URL is a TURN relay.
    public var isTURN: Bool { urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }

    /// Cloudflare's credential-free STUN, the fallback when TURN minting is
    /// unavailable (b2-webrtc.md section 5).
    public static let cloudflareSTUN = ICEServer(urls: ["stun:stun.cloudflare.com:3478"])
}
