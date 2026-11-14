import Foundation

/// How a cookie-store read failed, as far as choosing the next candidate goes.
///
/// A permission denial is checked before a missing file so an ambiguous error
/// fails closed: the reader reports it instead of falling through to an older
/// store.
enum SafariCookieStoreErrorKind: Equatable, Sendable {
    /// The path does not exist, so the next candidate may be tried.
    case missing
    /// macOS refused access, for the reason given.
    case permissionDenied(SafariCookieStoreAccessDenial)
    /// Any other failure, such as an unreadable or damaged file.
    case other

    /// Classifies a read error, looking one level into `NSUnderlyingErrorKey`.
    ///
    /// A POSIX cause decides the kind of denial: `EPERM` is a privacy block and
    /// `EACCES` a file-permission block. A Cocoa permission error with neither
    /// is a denial of unspecified cause.
    init(classifying error: any Error) {
        let topLevel = error as NSError
        let errors = [topLevel] + [topLevel.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        if errors.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EPERM) }) {
            self = .permissionDenied(.privacyProtected)
        } else if errors.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EACCES) }) {
            self = .permissionDenied(.filePermissions)
        } else if errors.contains(where: {
            $0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileReadNoPermission.rawValue
        }) {
            self = .permissionDenied(.unspecified)
        } else if errors.contains(where: Self.isMissingFile) {
            self = .missing
        } else {
            self = .other
        }
    }

    /// Whether `error` is one of the Cocoa or POSIX codes for a file that does not exist.
    private static func isMissingFile(_ error: NSError) -> Bool {
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == CocoaError.fileReadNoSuchFile.rawValue
                || error.code == CocoaError.fileNoSuchFile.rawValue
        case NSPOSIXErrorDomain:
            return error.code == Int(ENOENT)
        default:
            return false
        }
    }
}
