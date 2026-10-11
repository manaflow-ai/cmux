import Foundation

/// The sentences of cmux's error page for Chromium failures (`ChromiumNetError`).
extension Strings {
    static var netErrorNotFound: String {
        String(localized: "browser.netError.notFound", defaultValue: "The server’s address could not be found.", bundle: .module)
    }
    static var netErrorRefused: String {
        String(localized: "browser.netError.refused", defaultValue: "The server refused the connection.", bundle: .module)
    }
    static var netErrorTimedOut: String {
        String(localized: "browser.netError.timedOut", defaultValue: "The server took too long to respond.", bundle: .module)
    }
    static var netErrorOffline: String {
        String(localized: "browser.netError.offline", defaultValue: "You’re not connected to the internet.", bundle: .module)
    }
    static var netErrorCertificate: String {
        String(localized: "browser.netError.certificate", defaultValue: "Its certificate is not valid.", bundle: .module)
    }
    static var netErrorGeneric: String {
        String(localized: "browser.netError.generic", defaultValue: "The page could not be loaded.", bundle: .module)
    }
}
