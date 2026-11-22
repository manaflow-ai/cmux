/// Why a picture was taken: an update's relaunch, or `cmux app quit --keep-sessions`.
public nonisolated enum RelaunchCoverCause: String, Codable, Sendable {
    case update
    case keepSessionsQuit = "keep_sessions_quit"
}

/// Rust's decision (`CoverPlan`): `reason` is `show` or why not, `windows` front first (empty unless shown).
public nonisolated struct RelaunchCoverPlan: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public var id: String
        public var frame: RelaunchCoverRect
        public var order: UInt32
        public var key: Bool
        public var imagePath: String
        public var surfaces: [RelaunchCoverSurface]
    }

    public var reason: String
    public var failedWindow: String?
    public var windows: [Window]
    /// The plan as Rust wrote it, handed back to the reveal and the clear.
    var json = ""

    public var shows: Bool { reason == "show" }

    enum CodingKeys: String, CodingKey { case reason, failedWindow, windows }
}

/// How a window's picture gives way to its live content (`launch.relaunchCoverSwap`; Rust `SwapStyle`).
public nonisolated enum RelaunchCoverStyle: UInt8, Sendable {
    case instant = 0
    case crossfade = 1
    case progressive = 2
}
