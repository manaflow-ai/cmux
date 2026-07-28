import Bonsplit
import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    struct PendingCreatedPaneFocusRequest {
        let requestID: UUID
        let preexistingPaneIDs: Set<Int>
        var candidatePaneID: Int?
    }

    /// Whether nested focus moved, reached a valid boundary, or could not
    /// resolve authoritative pane ownership.
    enum FocusNavigationResult {
        /// Focus moved to a mapped pane inside the mirror.
        case moved
        /// The mapped focused pane has no neighbor in the requested direction.
        case edge
        /// Current or destination pane ownership could not be resolved.
        case invalid
    }

    /// Moves user focus inside this window's nested pane tree and establishes
    /// first responder on the destination surface. Remote active-pane events use
    /// ``focusBonsplitPane(forTmuxPane:)`` instead and therefore never steal key
    /// focus from the user.
    @discardableResult
    func navigateFocus(direction: NavigationDirection) -> FocusNavigationResult {
        guard let focusedPane = bonsplitController.focusedPaneId,
              let focusedTmuxPaneId = paneIdByBonsplitPane[focusedPane],
              panel(forPane: focusedTmuxPaneId) != nil else { return .invalid }
        guard let destinationPane = bonsplitController.adjacentPane(
            to: focusedPane,
            direction: direction
        ) else { return .edge }
        guard let tmuxPaneId = paneIdByBonsplitPane[destinationPane],
              let panel = panel(forPane: tmuxPaneId) else { return .invalid }

        bonsplitController.focusPane(destinationPane)
        guard bonsplitController.focusedPaneId == destinationPane else { return .invalid }
        if activePaneId != tmuxPaneId {
            setActivePane(tmuxPaneId, fromTmux: false)
        }
        panel.hostedView.moveFocus()
        return .moved
    }

    func seedActivePaneIfNeeded() {
        let live = renderedLayout.paneIDsInOrder
        let remoteActive = connection?.activePaneByWindow[windowId]
        let seed = remoteActive.flatMap { live.contains($0) ? $0 : nil } ?? live.first
        if activePaneId.map({ live.contains($0) }) != true, let seed {
            setActivePane(seed, fromTmux: true)
        } else if let activePaneId {
            setActivePane(activePaneId, fromTmux: true)
        }
    }

    func isFocused(tabId: TabID) -> Bool {
        tmuxPaneId(forTab: tabId).map { $0 == activePaneId } ?? false
    }

    func focusBonsplitPane(forTmuxPane paneId: Int) {
        // Reconciles reassert the active pane on every layout echo. Skip an
        // unchanged focus so remote truth cannot disturb the first responder.
        guard let bonsplitPane = paneIdByPaneId[paneId],
              bonsplitController.focusedPaneId != bonsplitPane else { return }
        isApplyingTmuxFocus = true
        bonsplitController.focusPane(bonsplitPane)
        isApplyingTmuxFocus = false
    }

    func noteCreatedPaneFocusRequestAccepted(requestID: UUID) {
        pendingCreatedPaneFocusRequests.append(PendingCreatedPaneFocusRequest(
            requestID: requestID,
            preexistingPaneIDs: Set(layout.paneIDsInOrder),
            candidatePaneID: nil
        ))
    }

    func cancelPendingCreatedPaneFocus(requestID: UUID) {
        pendingCreatedPaneFocusRequests.removeAll { $0.requestID == requestID }
        completePendingCreatedPaneFocusIfMounted()
    }

    func cancelPendingCreatedPaneFocus(candidatePaneID: Int) {
        pendingCreatedPaneFocusRequests.removeAll { $0.candidatePaneID == candidatePaneID }
        completePendingCreatedPaneFocusIfMounted()
    }

    func cancelPendingCreatedPaneFocus() {
        pendingCreatedPaneFocusRequests.removeAll()
    }

    func cancelPendingCreatedPaneFocus(competingPaneID: Int) {
        pendingCreatedPaneFocusRequests.removeAll {
            $0.candidatePaneID != competingPaneID
        }
    }

    func noteAuthoritativeCreatedPaneCandidate(paneID: Int) {
        guard !pendingCreatedPaneFocusRequests.contains(where: {
            $0.candidatePaneID == paneID
        }) else {
            completePendingCreatedPaneFocusIfMounted()
            return
        }
        guard let index = pendingCreatedPaneFocusRequests.firstIndex(where: {
            $0.candidatePaneID == nil && !$0.preexistingPaneIDs.contains(paneID)
        }) else {
            completePendingCreatedPaneFocusIfMounted()
            return
        }
        pendingCreatedPaneFocusRequests[index].candidatePaneID = paneID
        completePendingCreatedPaneFocusIfMounted()
    }

    func reconcilePendingCreatedPaneFocus(authoritativePaneID: Int?) {
        if let authoritativePaneID {
            pendingCreatedPaneFocusRequests.removeAll {
                $0.candidatePaneID.map { $0 != authoritativePaneID } ?? false
            }
            noteAuthoritativeCreatedPaneCandidate(paneID: authoritativePaneID)
        } else {
            completePendingCreatedPaneFocusIfMounted()
        }
    }

    func handlePaneSurfaceProgress() {
        completePendingCreatedPaneFocusIfMounted()
    }

    private func completePendingCreatedPaneFocusIfMounted() {
        while let request = pendingCreatedPaneFocusRequests.first,
              let paneID = request.candidatePaneID {
            guard layout.paneIDsInOrder.contains(paneID),
                  let panel = panel(forPane: paneID),
                  panel.hostedView.isVisibleInUI,
                  panel.hostedView.superview != nil,
                  let window = panel.hostedView.window else {
                return
            }
            guard activePaneId == paneID,
                  window.isKeyWindow else {
                pendingCreatedPaneFocusRequests.removeFirst()
                continue
            }
            focusBonsplitPane(forTmuxPane: paneID)
            guard bonsplitController.focusedPaneId.flatMap({ paneIdByBonsplitPane[$0] }) == paneID else {
                pendingCreatedPaneFocusRequests.removeFirst()
                continue
            }
            panel.hostedView.moveFocus()
            guard panel.hostedView.isSurfaceViewFirstResponder() else { return }
            pendingCreatedPaneFocusRequests.removeAll { $0.requestID == request.requestID }
        }
    }
}
