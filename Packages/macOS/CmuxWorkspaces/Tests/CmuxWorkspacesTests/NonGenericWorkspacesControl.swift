import Observation
import Foundation
@testable import CmuxWorkspaces

/// The same three stored members on a non-generic `@Observable` class used as
/// the per-read control for the workspace model benchmark.
@MainActor
@Observable
final class NonGenericWorkspacesControl {
    var tabs: [ReadCostStubTab] = []
    var workspaceGroups: [WorkspaceGroup] = []
    var selectedTabId: UUID?
}
