import CmuxMobileShellModel
import Observation

/// Session-scoped workspace filters shared by every presentation of the
/// workspace root, including the native iOS search tab.
@Observable
final class WorkspaceListFilterState {
    var filter: MobileWorkspaceListFilter

    init(filter: MobileWorkspaceListFilter = .all) {
        self.filter = filter
    }
}
