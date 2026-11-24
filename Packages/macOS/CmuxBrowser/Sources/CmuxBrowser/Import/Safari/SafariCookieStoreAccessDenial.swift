/// Why macOS refused to let cmux read a Safari cookie store, which decides the
/// recovery step a warning suggests.
public enum SafariCookieStoreAccessDenial: Equatable, Sendable {
    /// A privacy protection blocked the read (POSIX `EPERM`). Granting cmux
    /// Full Disk Access fixes it.
    case privacyProtected
    /// The file's owner or permissions do not let this user read it (POSIX
    /// `EACCES`). Full Disk Access does not help; the file's permissions do.
    case filePermissions
    /// The read was refused but the error carried no POSIX cause. Full Disk
    /// Access is the likely fix for Safari's protected container.
    case unspecified
}
