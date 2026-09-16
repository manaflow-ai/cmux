import Observation

/// Unsaved edits belong to the Settings window, so replacing a category's
/// controls does not discard them. Nothing here is persisted automatically.
@MainActor
@Observable
final class SettingsPageDrafts {
    var httpAllowlistDraft = ""
    var httpAllowlistSyncedValue = ""
    var httpAllowlistLoaded = false
    var urlAllowlistDraft = ""
    var urlAllowlistSyncedValue = ""
    var urlAllowlistLoaded = false
    var editedPort: Int?
    var mobilePortApplyResult: MobilePairingPortApplyResult?
    var isApplyingMobilePort = false
    var socketPasswordDraft = ""
}
