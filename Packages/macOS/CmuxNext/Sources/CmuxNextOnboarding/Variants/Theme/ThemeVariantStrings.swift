import Foundation

/// Copy for the Theme screen variants (table OnboardingVariantsTheme).
/// Copy the Standard screen shares stays in `OnboardingStrings`.
enum ThemeVariantStrings {
    static var titleLook: String {
        String(localized: "onboarding.v.theme.title.look", defaultValue: "Pick a Look", table: "OnboardingVariantsTheme", bundle: .module)
    }
    static var titleColors: String {
        String(localized: "onboarding.v.theme.title.colors", defaultValue: "Colors", table: "OnboardingVariantsTheme", bundle: .module)
    }
    static var titleQuestion: String {
        String(localized: "onboarding.v.theme.title.question", defaultValue: "How should cmux look?", table: "OnboardingVariantsTheme", bundle: .module)
    }
    static var sentenceLive: String {
        String(localized: "onboarding.v.theme.sentence.live", defaultValue: "Changes apply right away.", table: "OnboardingVariantsTheme", bundle: .module)
    }
    static var sentenceWindow: String {
        String(localized: "onboarding.v.theme.sentence.window", defaultValue: "This window changes with it.",
               table: "OnboardingVariantsTheme", bundle: .module)
    }
    static var dark: String {
        String(localized: "onboarding.v.theme.dark", defaultValue: "Dark", table: "OnboardingVariantsTheme", bundle: .module)
    }
    static var light: String {
        String(localized: "onboarding.v.theme.light", defaultValue: "Light", table: "OnboardingVariantsTheme", bundle: .module)
    }
    static var previous: String {
        String(localized: "onboarding.v.theme.previous", defaultValue: "Previous Theme", table: "OnboardingVariantsTheme", bundle: .module)
    }
    static var next: String {
        String(localized: "onboarding.v.theme.next", defaultValue: "Next Theme", table: "OnboardingVariantsTheme", bundle: .module)
    }
}
