import Foundation

/// Applies the cmux app catalog to every CLI `String(localized:defaultValue:)` call.
///
/// The CLI is shipped inside `Contents/Resources/bin`, while the catalog belongs
/// to the enclosing app bundle. Keeping this overload in the CLI target preserves
/// the existing call sites and keeps the English default when no app bundle exists.
extension String {
    init(localized key: String, defaultValue: String) {
        self = CMUXDiffViewerLocalization.string(key, defaultValue: defaultValue)
    }
}
