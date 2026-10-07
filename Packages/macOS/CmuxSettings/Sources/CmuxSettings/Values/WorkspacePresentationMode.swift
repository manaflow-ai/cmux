import Foundation

/// Chrome density for the main workspace window.
public enum WorkspacePresentationMode: String, CaseIterable, Sendable, SettingCodable {
    case standard, minimal
}
