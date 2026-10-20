import Foundation

// cmux refused a passkey request of a page an agent drives, asked in the
// prompt bar (plans/cmux-next/passkeys.md 3.5).
extension Strings {
    static func agentPasskeyRefused(_ origin: String) -> String {
        guard !origin.isEmpty else {
            return String(localized: "browser.agentPasskey.refused.thisPage",
                          defaultValue: "cmux blocked an agent’s passkey sign-in on this page. Only you can sign in with a passkey.",
                          bundle: .module)
        }
        return String(localized: "browser.agentPasskey.refused",
                      defaultValue: "cmux blocked an agent’s passkey sign-in on \(origin). Only you can sign in with a passkey.",
                      bundle: .module)
    }
    static var agentPasskeySignInYourself: String {
        String(localized: "browser.agentPasskey.signInYourself", defaultValue: "Sign in yourself", bundle: .module)
    }
}
