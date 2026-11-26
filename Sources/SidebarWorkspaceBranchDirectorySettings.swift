import CmuxSettings
import Foundation

/// Resolved branch and directory presentation settings shared by both sidebar renderers.
///
/// The legacy layout preference controls branch topology and, when vertical,
/// carries its historical stacked branch/directory presentation. The newer
/// placement preference can opt an inline branch topology into those stacked
/// subrows. Keeping that compatibility rule here prevents either renderer from
/// replacing or reinterpreting the shipped Bool preference.
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
        let usesVerticalBranchLayout = settings.value(for: sidebar.branchVerticalLayout)
        let explicitlyStacksBranchDirectory = settings.value(for: sidebar.stackBranchDirectory)
        branchLayout = usesVerticalBranchLayout
            ? .vertical
            : .inline
        branchDirectoryPlacement = SidebarCatalogSection.stacksBranchAndDirectory(
            vertical: usesVerticalBranchLayout,
            explicit: explicitlyStacksBranchDirectory
        )
            ? .stacked
            : .inline
        usesLastSegmentPath = settings.value(for: sidebar.pathLastSegmentOnly)
    }
}
