public import Foundation

/// What ``VerificationMessageParser`` read from one email. The policy, not
/// the parser, decides what a page may get.
public nonisolated struct VerificationMessage: Sendable, Hashable {
    /// Every distinct code next to a code word, normalized (no spaces or
    /// dashes), in the order found. More than one means ambiguous.
    public var codes: [String] = []
    /// The origin-bound line, when the message ends with one.
    public var originBoundCode: OriginBoundCode?
    /// Every distinct https link without user info or a non-default port.
    public var links: [URL] = []

    public init(codes: [String] = [], originBoundCode: OriginBoundCode? = nil, links: [URL] = []) {
        self.codes = codes
        self.originBoundCode = originBoundCode
        self.links = links
    }
}
