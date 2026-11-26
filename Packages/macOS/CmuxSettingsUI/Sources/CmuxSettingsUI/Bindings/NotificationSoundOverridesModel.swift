import CmuxSettings
import Observation

/// Caches the parsed notification-sound matrix for the Settings UI.
///
/// The backing setting remains a JSON string for compatibility with the
/// UserDefaults import path. This model parses each distinct committed string
/// once, so the matrix view can render repeatedly without decoding on every
/// body evaluation.
@MainActor
@Observable
final class NotificationSoundOverridesModel {
    /// The latest raw value observed from the settings store.
    private(set) var rawJSON: String
    /// The bounded decoded matrix, or `nil` when the persisted value is invalid.
    private(set) var parsed: NotificationSoundOverrides?

    init(initialJSON: String) {
        rawJSON = initialJSON
        parsed = Self.parse(initialJSON)
    }

    /// Reconciles a newly committed raw setting value.
    func accept(_ newJSON: String) {
        guard newJSON != rawJSON else { return }
        rawJSON = newJSON
        parsed = Self.parse(newJSON)
    }

    /// Whether the persisted value is non-empty but failed bounded decoding.
    var isMalformed: Bool {
        parsed == nil && !rawJSON.isEmpty
    }

    private static func parse(_ json: String) -> NotificationSoundOverrides? {
        json.isEmpty ? .empty : NotificationSoundOverrides(jsonString: json)
    }
}
