import Foundation

/// A system error in a person's words: no network, a timeout, a full or read-only disk, no permission, a missing or
/// taken name. Any other error reads as ``generic``, never its `localizedDescription` or `String(describing:)` (which
/// print "Error Domain=… Code=…"); a log keeps the raw error. Pure.
///
/// Leo, 2026-11-12: "we want good error states. We don't want busted errors."
public nonisolated enum PlainErrorText {
    /// One kind of failure a person can act on.
    public nonisolated enum Kind: Sendable, Equatable {
        case offline, timedOut, unreachable, secureConnection, noSpace, readOnly, permission, notFound, exists
    }

    /// `error`'s words: ``words(_:)``, else ``generic``.
    public static func text(_ error: any Error) -> String {
        words(error) ?? generic
    }

    /// `error` as a person reads it: ``words(_:)``; else the `errorDescription` cmux's own errors write for a
    /// person (a system error's is Cocoa's text, never shown); else ``generic``.
    public static func personal(_ error: any Error) -> String {
        if let words = words(error) { return words }
        if !isSystem(error), let text = (error as? any LocalizedError)?.errorDescription { return text }
        return generic
    }

    /// The plain sentence for an error cmux knows; nil for any other.
    public static func words(_ error: any Error) -> String? {
        kind(of: error).map(words)
    }

    /// The kind of `error`, read from `URLError`, `CocoaError`, `POSIXError` and their `NSError` domains, then the
    /// error it wraps (`NSUnderlyingErrorKey`); nil when none is known.
    public static func kind(of error: any Error) -> Kind? {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 4 {
            if let kind = kind(domain: ns.domain, code: ns.code) { return kind }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }

    /// Whether `error` is the system's (a Cocoa, URL, POSIX or OSStatus error), whose own text is Cocoa's, not cmux's.
    public static func isSystem(_ error: any Error) -> Bool {
        [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSMachErrorDomain]
            .contains((error as NSError).domain)
    }

    static func kind(domain: String, code: Int) -> Kind? {
        switch domain {
        case NSURLErrorDomain: urlKind(URLError.Code(rawValue: code))
        case NSCocoaErrorDomain: cocoaKind(CocoaError.Code(rawValue: code))
        case NSPOSIXErrorDomain: posixKind(Int32(truncatingIfNeeded: code))
        default: nil
        }
    }

    static func urlKind(_ code: URLError.Code) -> Kind? {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: .offline
        case .timedOut: .timedOut
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .cannotLoadFromNetwork: .unreachable
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: .secureConnection
        default: nil
        }
    }

    static func cocoaKind(_ code: CocoaError.Code) -> Kind? {
        switch code {
        case .fileWriteOutOfSpace: .noSpace
        case .fileWriteVolumeReadOnly: .readOnly
        case .fileReadNoPermission, .fileWriteNoPermission: .permission
        case .fileNoSuchFile, .fileReadNoSuchFile: .notFound
        case .fileWriteFileExists: .exists
        default: nil
        }
    }

    static func posixKind(_ code: Int32) -> Kind? {
        switch code {
        case ENOSPC, EDQUOT: .noSpace
        case EROFS: .readOnly
        case EACCES, EPERM: .permission
        case ENOENT: .notFound
        case EEXIST: .exists
        case ETIMEDOUT: .timedOut
        case ENETDOWN, ENETUNREACH: .offline
        case ECONNREFUSED, EHOSTUNREACH, EHOSTDOWN: .unreachable
        default: nil
        }
    }

    /// The sentence for `kind` (Localizable.xcstrings).
    public static func words(_ kind: Kind) -> String {
        switch kind {
        case .offline:
            String(localized: "error.plain.offline", defaultValue: "You're offline. Check your network, then try again.", bundle: .module)
        case .timedOut:
            String(localized: "error.plain.timedOut", defaultValue: "The connection timed out. Check your network, then try again.",
                   bundle: .module)
        case .unreachable:
            String(localized: "error.plain.unreachable", defaultValue: "cmux couldn't reach the server. Check your network, then try again.",
                   bundle: .module)
        case .secureConnection:
            String(localized: "error.plain.secureConnection", defaultValue: "cmux couldn't make a secure connection. Try again later.",
                   bundle: .module)
        case .noSpace:
            String(localized: "error.plain.noSpace", defaultValue: "The disk is full. Free some space, then try again.", bundle: .module)
        case .readOnly:
            String(localized: "error.plain.readOnly", defaultValue: "The disk is read-only.", bundle: .module)
        case .permission:
            String(localized: "error.plain.permission", defaultValue: "cmux doesn't have permission to do that.", bundle: .module)
        case .notFound:
            String(localized: "error.plain.notFound", defaultValue: "The file or folder isn't there anymore.", bundle: .module)
        case .exists:
            String(localized: "error.plain.exists", defaultValue: "An item with that name already exists.", bundle: .module)
        }
    }

    /// The line for an error cmux has no words for.
    public static var generic: String {
        String(localized: "error.plain.generic", defaultValue: "Something went wrong. Try again.", bundle: .module)
    }
}
