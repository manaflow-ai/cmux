/// Where one cookie import ask is (``CookieImportAsk/phase``); the card draws each one.
public enum CookieImportPhase: Sendable, Equatable {
    /// Waiting for the person's Allow or Deny.
    case asking
    /// Allowed: macOS's prompt is up or the cookies are being read and written.
    case reading
    /// Done: the import's audit record (its counts and sites; Remove takes them out again).
    case imported(CookieImportRecord)
    /// Ended with nothing imported: denied, timed out, nothing matched or failed; the text says which.
    case ended(String)
    /// The person removed what this import brought in.
    case removed(CookieImportRecord)

    /// Whether the person's answer is still open.
    public var isAsking: Bool { self == .asking }
}
