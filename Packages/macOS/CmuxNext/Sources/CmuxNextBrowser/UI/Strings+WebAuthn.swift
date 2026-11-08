import Foundation

/// Strings of the passkey request dialog for Chromium pages nobody sees and agent tabs
/// (`CEFWebAuthnPrompts`).
extension Strings {
    static func webAuthnSignInTitle(_ site: String) -> String {
        String(localized: "browser.webauthn.signInTitle", defaultValue: "Sign in to \(site) with a passkey?", bundle: .module)
    }
    static func webAuthnCreateTitle(_ site: String) -> String {
        String(localized: "browser.webauthn.createTitle", defaultValue: "Create a passkey for \(site)?", bundle: .module)
    }
    static func webAuthnFrame(_ topOrigin: String) -> String {
        String(localized: "browser.webauthn.frame", defaultValue: "A frame inside \(topOrigin) asks.", bundle: .module)
    }
    static func webAuthnTab(_ name: String) -> String {
        String(localized: "browser.webauthn.tab", defaultValue: "Tab: \(name)", bundle: .module)
    }
    static var webAuthnAgent: String {
        String(localized: "browser.webauthn.agent", defaultValue: "An agent drives this tab and started this request.", bundle: .module)
    }
    static var webAuthnNoGesture: String {
        String(localized: "browser.webauthn.noGesture", defaultValue: "The page asked by itself, with no click or key press.", bundle: .module)
    }
    static var webAuthnNotOnScreen: String {
        String(localized: "browser.webauthn.notOnScreen", defaultValue: "The page is not on screen.", bundle: .module)
    }
    static var webAuthnSignInNext: String {
        String(localized: "browser.webauthn.signInNext",
               defaultValue: "Continue to choose a passkey with Touch ID, your phone or a security key.", bundle: .module)
    }
    static var webAuthnCreateNext: String {
        String(localized: "browser.webauthn.createNext",
               defaultValue: "Continue to save a new passkey with Touch ID, your phone or a security key.", bundle: .module)
    }
    static var webAuthnCancel: String {
        String(localized: "browser.webauthn.cancel", defaultValue: "Cancel", bundle: .module)
    }
    static var webAuthnContinue: String {
        String(localized: "browser.webauthn.continue", defaultValue: "Continue", bundle: .module)
    }
}
