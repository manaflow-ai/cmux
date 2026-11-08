import Foundation

/// How a cookie-store read failed, as far as choosing the next candidate goes.
///
/// A permission denial is checked before a missing file so an ambiguous error
/// fails closed: the reader reports it instead of falling through to an older
/// store.
enum SafariCookieStoreErrorKind: Equatable, Sendable {
    /// The path does not exist, so the next candidate may be tried.
    case missing
    /// macOS refused access (TCC or POSIX permissions).
    case permissionDenied
    /// Any other failure, such as an unreadable or damaged file.
    case other

    /// Classifies a read error, looking one level into `NSUnderlyingErrorKey`.
    init(classifying error: any Error) {
        let topLevel = error as NSError
        let errors = [topLevel] + [topLevel.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        if errors.contains(where: Self.isPermissionDenied) {
            self = .permissionDenied
        } else if errors.contains(where: Self.isMissingFile) {
            self = .missing
        } else {
            self = .other
        }
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == CocoaError.fileReadNoPermission.rawValue
        case NSPOSIXErrorDomain:
            return error.code == Int(EPERM) || error.code == Int(EACCES)
        default:
            return false
        }
    }

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
