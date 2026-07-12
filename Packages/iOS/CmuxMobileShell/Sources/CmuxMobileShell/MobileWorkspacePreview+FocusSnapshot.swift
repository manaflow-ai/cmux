internal import CmuxMobileRPC
internal import CmuxMobileShellModel

extension MobileWorkspacePreview {
    @discardableResult
    mutating func applyFocusSnapshot(
        _ event: MobileWorkspaceFocusEvent
    ) -> MobileWorkspaceFocusAppliedDimensions {
        applyValidatedFocusSnapshot(
            paneID: event.focusedPaneID.map(MobilePanePreview.ID.init(rawValue:)),
            terminalID: event.selectedTerminalID.map(MobileTerminalPreview.ID.init(rawValue:))
        )
    }

    mutating func preserveFocusSnapshot(
        from existing: MobileWorkspacePreview,
        dimensions: MobileWorkspaceFocusAppliedDimensions = .all
    ) {
        _ = applyValidatedFocusSnapshot(
            paneID: existing.focusedPaneID,
            terminalID: existing.selectedTerminalID,
            dimensions: dimensions
        )
    }

    @discardableResult
    mutating func applyValidatedFocusSnapshot(
        paneID: MobilePanePreview.ID?,
        terminalID: MobileTerminalPreview.ID?,
        dimensions: MobileWorkspaceFocusAppliedDimensions = .all
    ) -> MobileWorkspaceFocusAppliedDimensions {
        var applied = MobileWorkspaceFocusAppliedDimensions(pane: false, terminal: false)
        if dimensions.pane {
            switch ValidatedFocusDimension(
                requestedID: paneID,
                isAvailable: { requestedID in panes.contains(where: { $0.id == requestedID }) }
            ) {
            case .clear:
                focusedPaneID = nil
                for index in panes.indices {
                    panes[index].isFocused = false
                }
                applied.pane = true
            case .apply(let appliedPaneID):
                focusedPaneID = appliedPaneID
                for index in panes.indices {
                    panes[index].isFocused = panes[index].id == appliedPaneID
                }
                applied.pane = true
            case .unchanged:
                break
            }
        }

        if dimensions.terminal {
            switch ValidatedFocusDimension(
                requestedID: terminalID,
                isAvailable: { requestedID in terminals.contains(where: { $0.id == requestedID }) }
            ) {
            case .clear:
                selectedTerminalID = nil
                for index in terminals.indices {
                    terminals[index].isFocused = false
                }
                applied.terminal = true
            case .apply(let appliedTerminalID):
                selectedTerminalID = appliedTerminalID
                for index in terminals.indices {
                    terminals[index].isFocused = terminals[index].id == appliedTerminalID
                }
                applied.terminal = true
            case .unchanged:
                break
            }
        }
        return applied
    }
}

private enum ValidatedFocusDimension<ID: Equatable> {
    case clear
    case apply(ID)
    case unchanged

    init(requestedID: ID?, isAvailable: (ID) -> Bool) {
        guard let requestedID else {
            self = .clear
            return
        }
        if isAvailable(requestedID) {
            self = .apply(requestedID)
        } else {
            self = .unchanged
        }
    }
}
