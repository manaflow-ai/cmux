/// An origin-bound one-time code: the last line `@example.com #123456` of a
/// message (WICG sms-one-time-codes, Apple's and Chrome's format). The code
/// is for a page on exactly `host`.
public nonisolated struct OriginBoundCode: Sendable, Hashable {
    /// The lowercased host the code is bound to.
    public let host: String
    public let code: String

    public init(host: String, code: String) {
        self.host = host
        self.code = code
    }
}
