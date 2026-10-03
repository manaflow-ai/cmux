public import Foundation

/// An account as every caller sees it: an opaque per-user `handle`
/// (`acct_…`) and a redacted `display`. The raw email or login it was made
/// from never leaves the code that read it (detection, the CodeRouter
/// client boundary). The handle is stable for one user and one identity,
/// and different on another Mac or user (``AccountLabeler``).
public struct AccountLabel: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let handle: String
    /// A plan or organization name, a user label, a masked key, or a
    /// shortened identity (`s…@e…`). Never matches an email pattern.
    public let display: String

    /// `display` is redacted again here, so no value of this type can hold an email.
    public init(handle: String, display: String) {
        self.handle = handle
        self.display = EmailRedaction.redactEmails(in: display)
    }

    private enum CodingKeys: String, CodingKey { case handle = "account", display = "label" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(handle: try container.decode(String.self, forKey: .handle), display: try container.decode(String.self, forKey: .display))
    }

    public var description: String { "\(handle) (\(display))" }
}

/// Email detection and redaction shared by detection, the CodeRouter
/// client boundary and the socket outputs.
public enum EmailRedaction {
    /// `local@domain.tld`, ASCII, case-insensitive.
    static func pattern() -> Regex<Substring> { #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}/# }

    public static func containsEmail(_ text: String) -> Bool { text.contains(pattern()) }

    /// Every email inside `text` replaced with its short form (`s…@e…`).
    public static func redactEmails(in text: String) -> String {
        guard text.contains("@") else { return text }
        return text.replacing(pattern()) { match in shorten(email: String(match.output)) }
    }

    /// An identity as a display: an email becomes `s…@e…`, anything else
    /// its first character and `…`. Never the full local part or domain.
    public static func redact(identity: String) -> String {
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.wholeMatch(of: pattern()) != nil { return shorten(email: trimmed) }
        return trimmed.first.map { "\($0)…" } ?? "…"
    }

    static func shorten(email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        let local = parts.first?.first.map(String.init) ?? ""
        let domain = parts.count > 1 ? parts[1].first.map(String.init) ?? "" : ""
        return "\(local)…@\(domain)…"
    }
}
