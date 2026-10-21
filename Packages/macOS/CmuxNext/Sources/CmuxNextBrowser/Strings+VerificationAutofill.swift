import Foundation

// Email verification AutoFill's offer, asked in the prompt bar
// (plans/cmux-next/email-verification-autofill/DESIGN.md).
extension Strings {
    static func verificationCodeOffer(site: String, code: String) -> String {
        String(localized: "browser.verification.codeOffer", defaultValue: "Verification code from \(site): \(code)", bundle: .module)
    }
    static func verificationLinkOffer(site: String) -> String {
        String(localized: "browser.verification.linkOffer", defaultValue: "Verification link from \(site)", bundle: .module)
    }
    static var verificationFillCode: String { String(localized: "browser.verification.fillCode", defaultValue: "Fill Code", bundle: .module) }
    static var verificationOpenLink: String { String(localized: "browser.verification.openLink", defaultValue: "Open Link", bundle: .module) }
    static var verificationNotNow: String { String(localized: "browser.verification.notNow", defaultValue: "Not Now", bundle: .module) }
}
