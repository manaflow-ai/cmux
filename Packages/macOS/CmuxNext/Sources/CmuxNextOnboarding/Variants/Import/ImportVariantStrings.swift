import Foundation

/// Copy for the Import screen variants (table OnboardingVariantsImport).
/// Copy the Standard screen shares stays in `OnboardingStrings`.
enum ImportVariantStrings {
    static var titleShort: String {
        String(localized: "onboarding.v.import.title.short", defaultValue: "Import", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var titleBring: String {
        String(localized: "onboarding.v.import.title.bring", defaultValue: "Bring Your Browsing", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var titleEverything: String {
        String(localized: "onboarding.v.import.title.everything", defaultValue: "Bring Everything Over", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var titleWhich: String {
        String(localized: "onboarding.v.import.title.which", defaultValue: "Which Profiles?", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var sentenceLocal: String {
        String(localized: "onboarding.v.import.sentence.local", defaultValue: "Nothing leaves this Mac.", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var sentenceBackground: String {
        String(localized: "onboarding.v.import.sentence.background", defaultValue: "It keeps going in the background.",
               table: "OnboardingVariantsImport", bundle: .module)
    }
    static var sentencePick: String {
        String(localized: "onboarding.v.import.sentence.pick", defaultValue: "Each profile becomes a cmux profile.",
               table: "OnboardingVariantsImport", bundle: .module)
    }
    static var everything: String {
        String(localized: "onboarding.v.import.everything", defaultValue: "Import everything", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var chooseProfiles: String {
        String(localized: "onboarding.v.import.chooseProfiles", defaultValue: "Choose Profiles", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var browsers: String {
        String(localized: "onboarding.v.import.column.browsers", defaultValue: "Browsers", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var bring: String {
        String(localized: "onboarding.v.import.column.bring", defaultValue: "Bring", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var edit: String {
        String(localized: "onboarding.v.import.edit", defaultValue: "Edit", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var from: String {
        String(localized: "onboarding.v.import.from", defaultValue: "From", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var allBrowsers: String {
        String(localized: "onboarding.v.import.allBrowsers", defaultValue: "All Browsers", table: "OnboardingVariantsImport", bundle: .module)
    }
    static var nothingSelected: String {
        String(localized: "onboarding.v.import.nothingSelected", defaultValue: "Nothing selected", table: "OnboardingVariantsImport", bundle: .module)
    }
    /// "3 of 4 profiles".
    static func selectedCount(_ selected: Int, _ total: Int) -> String {
        String(format: String(localized: "onboarding.v.import.selectedCount", defaultValue: "%1$lld of %2$lld profiles",
                              table: "OnboardingVariantsImport", bundle: .module), selected, total)
    }
}
