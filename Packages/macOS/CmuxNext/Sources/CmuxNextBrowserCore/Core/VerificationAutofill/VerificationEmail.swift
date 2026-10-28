public import Foundation

/// One email a mail source read while a page waited for a verification
/// email (plans/cmux-next/email-verification-autofill/DESIGN.md). It lives in
/// memory only. Its descriptions never show its text, so no log line, crash
/// report or debugger dump carries a code.
public nonisolated struct VerificationEmail: Sendable, Hashable, Identifiable {
    /// The source's id for the message (Mail.app message id, Gmail id): an
    /// email gives at most one offer, once.
    public let id: String
    /// The From address ("noreply@github.com"). Never a display name.
    public let senderAddress: String
    /// The source's verdict on the sender: true when DKIM (or DMARC) passed
    /// aligned with the From domain, false when it failed, nil when the
    /// source cannot tell. A link needs true; a code is refused on false.
    public let senderAuthenticated: Bool?
    public let subject: String
    /// The plain-text body (an HTML body converted to text by the source).
    public let body: String
    /// The `href` targets of an HTML body; plain-text links in `body` are
    /// found by the parser.
    public let links: [URL]
    public let receivedAt: Date

    /// - Parameters:
    ///   - id: The source's message id.
    ///   - senderAddress: The From address.
    ///   - senderAuthenticated: DKIM/DMARC result aligned with the From domain, or nil when unknown.
    ///   - subject: The subject line.
    ///   - body: The plain-text body.
    ///   - links: The HTML body's link targets.
    ///   - receivedAt: When the mailbox received it.
    public init(id: String, senderAddress: String, senderAuthenticated: Bool?, subject: String, body: String, links: [URL], receivedAt: Date) {
        self.id = id
        self.senderAddress = senderAddress
        self.senderAuthenticated = senderAuthenticated
        self.subject = subject
        self.body = body
        self.links = links
        self.receivedAt = receivedAt
    }
}

extension VerificationEmail: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VerificationEmail(id: \(id), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["id": id], displayStyle: .struct) }
}
