import Foundation

/// The first-run import card's words (RFD 0125 D4). Kind names, Import Into,
/// New Profile, Import and Not Now reuse the import step's.
extension OnboardingStrings {
    /// The card's title: "Bring Chrome to cmux".
    static func firstRunImportTitle(_ browser: String) -> String {
        String(format: String(localized: "onboarding.firstRunImport.title", defaultValue: "Bring %@ to cmux", bundle: .localizedModule), browser)
    }
    /// The label before the source browser and profile.
    static var firstRunImportFrom: String {
        String(localized: "onboarding.firstRunImport.from", defaultValue: "From", bundle: .localizedModule)
    }
    /// Stated under the kinds when Sign-ins go into a profile that has cookies of its own.
    static var firstRunImportReplacesCookies: String {
        String(localized: "onboarding.firstRunImport.replacesCookies",
               defaultValue: "Replace existing cookies: sign-ins from the import take the place of this profile’s for the same sites.",
               bundle: .localizedModule)
    }
    /// The mirror line: imported sign-ins keep following the other browser (`browser.import.cookieSync`).
    static func firstRunImportMirror(_ browser: String) -> String {
        String(format: String(localized: "onboarding.firstRunImport.mirror", defaultValue: "Keep sign-ins in sync with %@", bundle: .localizedModule), browser)
    }
    /// Under the mirror line: what it reads and where to turn it off.
    static var firstRunImportMirrorDetail: String {
        String(localized: "onboarding.firstRunImport.mirrorDetail",
               defaultValue: "Reads only that profile, on this Mac. Turn it off any time from the profile menu.",
               bundle: .localizedModule)
    }
}
