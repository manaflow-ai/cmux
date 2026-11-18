import Foundation

// Email verification AutoFill's offer, asked in the prompt bar
// (plans/cmux-next/email-verification-autofill/DESIGN.md).
extension Strings {
    static func verificationCodeOffer(site: String, code: String) -> String {
        String(localized: "browser.verification.codeOffer", defaultValue: "Verification code from \(site): \(code)", bundle: .l10n)
    }
    static func verificationLinkOffer(site: String) -> String {
        String(localized: "browser.verification.linkOffer", defaultValue: "Verification link from \(site)", bundle: .l10n)
    }
    static var verificationFillCode: String { String(localized: "browser.verification.fillCode", defaultValue: "Fill Code", bundle: .l10n) }
    static var verificationOpenLink: String { String(localized: "browser.verification.openLink", defaultValue: "Open Link", bundle: .l10n) }
    static var verificationNotNow: String { String(localized: "browser.verification.notNow", defaultValue: "Not Now", bundle: .l10n) }
    /// The suggestion under the code field: "Fill code 482 913".
    static func verificationSuggestionFill(code: String) -> String {
        String(localized: "browser.verification.suggestion.fill", defaultValue: "Fill code \(code)", bundle: .l10n)
    }
    /// Its second line: the sender's site, "From slack.com".
    static func verificationSuggestionFrom(site: String) -> String {
        String(localized: "browser.verification.suggestion.from", defaultValue: "From \(site)", bundle: .l10n)
    }
}
