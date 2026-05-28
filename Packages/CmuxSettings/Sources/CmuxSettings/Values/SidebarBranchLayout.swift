import Foundation

/// How the branch + directory metadata stacks under each workspace row.
public enum SidebarBranchLayout: String, CaseIterable, Sendable, SettingCodable {
    case vertical, inline
}
