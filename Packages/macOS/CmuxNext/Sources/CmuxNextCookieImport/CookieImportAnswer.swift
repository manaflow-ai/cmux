/// The person's answer on the consent panel.
enum CookieImportAnswer: Sendable, Equatable {
    case allow
    case deny
    /// No answer within the panel's limit; treated as Deny.
    case timedOut
}
