/// The identity of a problem: FNV-1a 64 over its source, message template and top frame
/// (Rust's `cmux-error-journal` `fingerprint`).
public struct ErrorFingerprint: Sendable, Hashable {
    /// 16 lowercase hex digits.
    public let hex: String

    /// Hashes one problem's identity.
    /// - Parameters:
    ///   - source: The event source.
    ///   - template: The normalized message (``ErrorNormalizer/template(_:)``).
    ///   - topFrame: The top frame, or nil.
    public init(source: String, template: String, topFrame: String?) {
        var request: [String: Any] = ["source": source, "template": template]
        if let topFrame { request["top_frame"] = topFrame }
        hex = ErrorJournalFFI.object("error_journal_fingerprint", request)?["fingerprint"] as? String ?? ""
    }
}
