import Foundation

/// Where a newly-created workspace lands in the sidebar.
public enum WorkspacePlacement: String, CaseIterable, Sendable, SettingCodable {
    case top, end, afterCurrent
}
