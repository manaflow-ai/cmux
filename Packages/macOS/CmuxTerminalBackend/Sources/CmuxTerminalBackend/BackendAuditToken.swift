/// The opaque audit token attached to a connected Unix-socket peer by macOS.
///
/// The eight words are intentionally not interpreted in this package. Code
/// that authenticates a peer must reconstruct `audit_token_t` and use the
/// operating system's `audit_token_to_*` and audit-token-aware process APIs.
public struct BackendAuditToken: Equatable, Sendable {
    public let word0: UInt32
    public let word1: UInt32
    public let word2: UInt32
    public let word3: UInt32
    public let word4: UInt32
    public let word5: UInt32
    public let word6: UInt32
    public let word7: UInt32

    /// Creates an opaque token from the exact eight kernel-provided words.
    public init(
        word0: UInt32,
        word1: UInt32,
        word2: UInt32,
        word3: UInt32,
        word4: UInt32,
        word5: UInt32,
        word6: UInt32,
        word7: UInt32
    ) {
        self.word0 = word0
        self.word1 = word1
        self.word2 = word2
        self.word3 = word3
        self.word4 = word4
        self.word5 = word5
        self.word6 = word6
        self.word7 = word7
    }
}
