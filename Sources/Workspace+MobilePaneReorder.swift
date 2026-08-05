import Bonsplit
import Foundation

extension Workspace {
    /// Moves complete pane contents between the existing split-tree slots.
    ///
    /// Pane identities and divider geometry remain stable. The requested IDs name
    /// the current pane content that should occupy each spatial slot, in the
    /// workspace's current spatial order.
    @discardableResult
    func applyMobilePaneOrder(_ requestedPaneIDs: [UUID]) -> Bool {
        let spatialPanes = spatiallyOrderedPaneIds
        guard !isRemoteTmuxMirror,
              layoutMode == .splits,
              bonsplitController.configuration.allowCrossPaneTabMove,
              requestedPaneIDs.count == spatialPanes.count,
              Set(requestedPaneIDs) == Set(spatialPanes),
              requestedPaneIDs != spatialPanes else {
            return requestedPaneIDs == spatialPanes
        }

        let panesByID = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { ($0.id, $0) }
        )
        guard spatialPanes.allSatisfy({ panesByID[$0] != nil }) else { return false }

        let tabsBySourcePaneID = Dictionary(
            uniqueKeysWithValues: spatialPanes.map { paneID in
                let pane = panesByID[paneID]!
                return (paneID, bonsplitController.tabs(inPane: pane).map(\.id))
            }
        )
        guard tabsBySourcePaneID.values.allSatisfy({ !$0.isEmpty }) else { return false }

        let selectedTabBySourcePaneID = Dictionary(
            uniqueKeysWithValues: spatialPanes.compactMap { paneID in
                let pane = panesByID[paneID]!
                return bonsplitController.selectedTab(inPane: pane).map { (paneID, $0.id) }
            }
        )
        let originallyFocusedPaneID = bonsplitController.focusedPaneId?.id
        var placeholderTabsByPaneID: [UUID: TabID] = [:]
        var mutationSucceeded = true

        mobilePaneLayoutPublicationSuppressionCount += 1
        performRemoteTmuxMirrorMutation {
            for paneID in spatialPanes {
                guard let pane = panesByID[paneID],
                      let placeholder = bonsplitController.createTab(
                        title: "\u{200B}",
                        icon: nil,
                        inPane: pane
                      ) else {
                    mutationSucceeded = false
                    break
                }
                placeholderTabsByPaneID[paneID] = placeholder
            }

            if mutationSucceeded {
                for (destinationIndex, sourcePaneID) in requestedPaneIDs.enumerated() {
                    let destinationPaneID = spatialPanes[destinationIndex]
                    guard sourcePaneID != destinationPaneID,
                          let destinationPane = panesByID[destinationPaneID],
                          let tabs = tabsBySourcePaneID[sourcePaneID] else {
                        continue
                    }
                    for (tabIndex, tabID) in tabs.enumerated()
                    where !bonsplitController.moveTab(
                        tabID,
                        toPane: destinationPane,
                        atIndex: tabIndex
                    ) {
                        mutationSucceeded = false
                        break
                    }
                    if !mutationSucceeded { break }
                }
            }

            if !mutationSucceeded {
                restoreMobilePaneOrder(
                    spatialPanes: spatialPanes,
                    panesByID: panesByID,
                    tabsBySourcePaneID: tabsBySourcePaneID
                )
            }

            for placeholder in placeholderTabsByPaneID.values {
                // Force-close bypasses close vetoes (e.g. a close-confirmation
                // sheet in flight on the Mac) that would otherwise leave
                // zero-width phantom tabs in the authoritative layout while
                // this reorder reports success. If a placeholder still survives,
                // fail the mutation so the phone reconciles instead of trusting
                // a success response that contains the phantom.
                if !requestCloseTab(placeholder, force: true),
                   panesByID.values.contains(where: { pane in
                       bonsplitController.tabs(inPane: pane).contains(where: { $0.id == placeholder })
                   }) {
                    mutationSucceeded = false
                }
            }

            let selectionPanes = mutationSucceeded
                ? requestedPaneIDs.enumerated().map { (spatialPanes[$0.offset], $0.element) }
                : spatialPanes.map { ($0, $0) }
            for (destinationPaneID, sourcePaneID) in selectionPanes {
                guard let selectedTab = selectedTabBySourcePaneID[sourcePaneID],
                      let destinationPane = panesByID[destinationPaneID] else {
                    continue
                }
                bonsplitController.focusPane(destinationPane)
                bonsplitController.selectTab(selectedTab)
            }
        }

        // The remote-mutation coordinator restores its entry focus when the
        // closure exits. Reassert the content-relative focus afterward, while
        // publication remains suppressed, so observers see only the final
        // authoritative topology.
        if let originallyFocusedPaneID {
            let restoredFocusedPaneID: UUID
            if mutationSucceeded,
               let destinationIndex = requestedPaneIDs.firstIndex(of: originallyFocusedPaneID) {
                restoredFocusedPaneID = spatialPanes[destinationIndex]
            } else {
                restoredFocusedPaneID = originallyFocusedPaneID
            }
            if let restoredFocusedPane = panesByID[restoredFocusedPaneID] {
                bonsplitController.focusPane(restoredFocusedPane)
            }
        }
        mobilePaneLayoutPublicationSuppressionCount -= 1

        guard mutationSucceeded else { return false }

        publishMobilePaneLayoutRevisionIfChanged()
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
        return true
    }

    private func restoreMobilePaneOrder(
        spatialPanes: [UUID],
        panesByID: [UUID: PaneID],
        tabsBySourcePaneID: [UUID: [TabID]]
    ) {
        for paneID in spatialPanes {
            guard let pane = panesByID[paneID],
                  let tabs = tabsBySourcePaneID[paneID] else {
                continue
            }
            for (tabIndex, tabID) in tabs.enumerated() {
                _ = bonsplitController.moveTab(tabID, toPane: pane, atIndex: tabIndex)
            }
        }
    }
}
