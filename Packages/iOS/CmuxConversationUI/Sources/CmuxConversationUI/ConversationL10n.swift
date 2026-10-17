import Foundation

/// Localized copy owned by the conversation feature. Keeping keys here makes
/// SwiftUI labels auditable and gives package resources one source of truth.
enum ConversationL10n {
    static func value(_ key: String, _ fallback: String) -> String {
        Bundle.module.localizedString(forKey: key, value: fallback, table: nil)
    }
}
