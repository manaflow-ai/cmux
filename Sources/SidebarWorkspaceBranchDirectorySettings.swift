import CmuxSettings
import Foundation

/// Resolved branch and directory presentation settings shared by both sidebar renderers.
///
/// Branch topology and branch/directory placement are independent axes backed by
/// different persisted keys. Keeping them in one named value prevents renderers
/// from treating the newer placement toggle as a replacement for the legacy
/// topology preference.
struct SidebarWorkspaceBranchDirectorySettings: Equatable {
    /// Whether multiple branches use separate rows or one compact row.
    enum BranchLayout: Equatable {
        case vertical
        case inline
    }

    /// Whether a branch and its directory share a row or use separate subrows.
    enum BranchDirectoryPlacement: Equatable {
        case stacked
        case inline
    }

    let branchLayout: BranchLayout
    let branchDirectoryPlacement: BranchDirectoryPlacement
    let usesLastSegmentPath: Bool

    init(defaults: UserDefaults) {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let sidebar = SidebarCatalogSection()
        branchLayout = settings.value(for: sidebar.branchVerticalLayout)
            ? .vertical
            : .inline
        branchDirectoryPlacement = settings.value(for: sidebar.stackBranchDirectory)
            ? .stacked
            : .inline
        usesLastSegmentPath = settings.value(for: sidebar.pathLastSegmentOnly)
    }
}
