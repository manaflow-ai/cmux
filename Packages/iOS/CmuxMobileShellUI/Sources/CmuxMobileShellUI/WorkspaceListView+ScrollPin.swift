import CmuxMobileShellModel

extension WorkspaceListView {
    /// The item-kind snapshot behind ``WorkspaceListScrollIndicatorStabilizer``.
    /// Mirrors, in order, exactly what the body mounts: the chrome row when
    /// present, then grouped items, the filter-empty row, or flat rows.
    var scrollPinModel: WorkspaceListScrollPinModel {
        var kinds: [WorkspaceListScrollPinKind] = []
        switch connectionChrome {
        case .recoveryBanner:
            if store != nil {
                kinds.append(.variable(id: "chrome.recoveryBanner"))
            }
        case .macStatusRow:
            kinds.append(.variable(id: "chrome.macStatusRow"))
        case .none:
            break
        }
        if rendersGroupedSections {
            for item in displayedGroupedListItems {
                switch item {
                case .groupHeader:
                    kinds.append(.groupHeader)
                case .groupFooter:
                    kinds.append(.groupFooter)
                case .workspace:
                    kinds.append(.workspaceRow)
                }
            }
        } else if showsFilterEmptyRow {
            kinds.append(.variable(id: "filterEmpty"))
        } else {
            kinds.append(
                contentsOf: repeatElement(.workspaceRow, count: displayedFlatWorkspaces.count)
            )
        }
        return WorkspaceListScrollPinModel(
            kinds: kinds,
            rowHeightsAreUniform: !wrapWorkspaceTitles
        )
    }
}
