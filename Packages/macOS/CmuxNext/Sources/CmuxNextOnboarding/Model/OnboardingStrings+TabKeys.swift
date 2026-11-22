import Foundation

/// The number keys step's text (D4).
extension OnboardingStrings {
    static var tabKeysTitle: String { String(localized: "onboarding.tabKeys.title", defaultValue: "Number Keys", bundle: .module) }
    static var tabKeysSubtitle: String {
        String(localized: "onboarding.tabKeys.subtitle", defaultValue: "What ⌃1…9 select.", bundle: .module)
    }
    static func tabKeysName(_ choice: TabKeysChoice) -> String {
        switch choice {
        case .tabs: String(localized: "onboarding.tabKeys.tabs", defaultValue: "Tabs", bundle: .module)
        case .spaces: String(localized: "onboarding.tabKeys.spaces", defaultValue: "Spaces", bundle: .module)
        }
    }
    /// The keys each choice gives, beside its radio.
    static func tabKeysDetail(_ choice: TabKeysChoice) -> String {
        switch choice {
        case .tabs: String(localized: "onboarding.tabKeys.tabs.detail", defaultValue: "⌃1…9 tabs · ⌃⌥1…9 Spaces", bundle: .module)
        case .spaces: String(localized: "onboarding.tabKeys.spaces.detail", defaultValue: "⌃1…9 Spaces · ⌃⌥1…9 tabs", bundle: .module)
        }
    }
}
