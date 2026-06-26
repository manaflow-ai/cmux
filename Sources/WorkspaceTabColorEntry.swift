import Foundation

/// A name + hex color palette entry for workspace tab colors.
///
/// Staged for CmuxWorkspaces (Wave 4 of the TabManager decomposition): the
/// palette value types and math move together when the workspace domain
/// package lands.
struct WorkspaceTabColorEntry: Equatable, Identifiable {
    let name: String
    let hex: String

    var id: String { name }
}
