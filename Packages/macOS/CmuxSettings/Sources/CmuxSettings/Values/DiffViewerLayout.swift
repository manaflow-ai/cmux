import Foundation

/// Default layout for newly opened diff viewers.
public enum DiffViewerLayout: String, CaseIterable, Sendable, SettingCodable {
    /// Show file changes in a single unified column.
    case unified

    /// Show old and new file content side by side.
    case split
}
