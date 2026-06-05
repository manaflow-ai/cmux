import Foundation

/// When to show the quit-confirmation dialog.
public enum ConfirmQuitMode: String, CaseIterable, Sendable, SettingCodable {
    case always
    case dirtyOnly = "dirty-only"
    case never
}
