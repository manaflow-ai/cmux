import Foundation

// A page's autofill, password and datalist suggestions in host mode (ChromiumHostSuggestionRows).
extension Strings {
    /// What VoiceOver calls the list of a field's suggestions.
    static var suggestionsList: String { String(localized: "browser.suggestions.list", defaultValue: "Suggestions", bundle: .module) }
    /// The delete button of a saved form entry, its tooltip and VoiceOver label.
    static var suggestionRemove: String {
        String(localized: "browser.suggestions.remove", defaultValue: "Remove Entry", bundle: .module)
    }
}
