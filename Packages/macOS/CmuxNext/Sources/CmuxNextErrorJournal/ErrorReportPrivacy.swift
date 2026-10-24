/// How one interpolated value of an ``ErrorReportMessage`` shows, as `Logger` decides it.
public enum ErrorReportPrivacy: Sendable, Equatable {
    /// The value as it is (secrets are still redacted, ``ErrorRedactor``).
    case `public`
    /// `<private>`, in the unified log and in the journal.
    case `private`
}
