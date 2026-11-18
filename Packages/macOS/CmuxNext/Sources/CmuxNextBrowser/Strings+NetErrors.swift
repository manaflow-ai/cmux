import Foundation

/// The sentences of cmux's error page for Chromium failures (`ChromiumNetError`).
extension Strings {
    nonisolated static var netErrorNotFound: String {
        String(localized: "browser.netError.notFound", defaultValue: "The server’s address could not be found.", bundle: .l10n)
    }
    nonisolated static var netErrorRefused: String {
        String(localized: "browser.netError.refused", defaultValue: "The server refused the connection.", bundle: .l10n)
    }
    nonisolated static var netErrorTimedOut: String {
        String(localized: "browser.netError.timedOut", defaultValue: "The server took too long to respond.", bundle: .l10n)
    }
    nonisolated static var netErrorOffline: String {
        String(localized: "browser.netError.offline", defaultValue: "You’re not connected to the internet.", bundle: .l10n)
    }
    nonisolated static var netErrorCertificate: String {
        String(localized: "browser.netError.certificate", defaultValue: "Its certificate is not valid.", bundle: .l10n)
    }
    nonisolated static var netErrorGeneric: String {
        String(localized: "browser.netError.generic", defaultValue: "The page could not be loaded.", bundle: .l10n)
    }
    nonisolated static var netErrorBlockedByAdministrator: String {
        String(localized: "browser.netError.blockedByAdministrator", defaultValue: "Your organization blocked this page.", bundle: .l10n)
    }
}
