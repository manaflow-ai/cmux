import Bonsplit
import Foundation

/// Persisted window state and Bonsplit contents for one workspace floating Dock.
struct SessionFloatingDockSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isPresented: Bool
    /// Per-window glass tint. Absent snapshots derive the Raycast-style tint from the Ghostty theme.
    var backgroundTintHex: String? = nil
    /// Absent in snapshots written before floating Dock contents were restorable.
    var content: SessionFloatingDockContentSnapshot? = nil
    /// Last global screen frame, used to remap the window across display sizes.
    var screenFrame: SessionRectSnapshot? = nil
    /// Display geometry associated with ``screenFrame``.
    var display: SessionDisplaySnapshot? = nil
    /// Exact remembered frames for recently-used display configurations.
    var configFrames: [SessionConfigFrameEntry]? = nil
}

struct SessionFloatingDockContentSnapshot: Codable, Sendable {
    var layout: SessionWorkspaceLayoutSnapshot
    var surfaces: [SessionFloatingDockSurfaceSnapshot]
    var focusedPanelId: UUID?
}

struct SessionFloatingDockSurfaceSnapshot: Codable, Sendable {
    var id: UUID
    var kind: DockSurfaceKind
    var terminal: SessionTerminalPanelSnapshot? = nil
    var browser: SessionBrowserPanelSnapshot? = nil
}

/// Shared capture/pruning for every session-persisted Bonsplit tree. Panel
/// creation stays container-specific, while layout serialization has one owner.
enum BonsplitSessionLayoutCodec {
    @MainActor
    static func capture(
        controller: BonsplitController,
        panelIdForTab: (TabID) -> UUID?
    ) -> SessionWorkspaceLayoutSnapshot {
        let panelIdsByTabId = Dictionary(uniqueKeysWithValues: controller.allTabIds.compactMap { tabId in
            panelIdForTab(tabId).map { (tabId.uuid, $0) }
        })
        return capture(
            node: controller.treeSnapshot(),
            controller: controller,
            panelIdsByTabId: panelIdsByTabId
        )
    }

    static func pruning(
        _ node: SessionWorkspaceLayoutSnapshot,
        keeping panelIdsToKeep: Set<UUID>
    ) -> SessionWorkspaceLayoutSnapshot? {
        switch node {
        case .pane(let pane):
            let panelIds = pane.panelIds.filter { panelIdsToKeep.contains($0) }
            guard !panelIds.isEmpty else { return nil }
            let selectedPanelId = pane.selectedPanelId.flatMap {
                panelIdsToKeep.contains($0) ? $0 : nil
            } ?? panelIds.first
            return .pane(SessionPaneLayoutSnapshot(
                panelIds: panelIds,
                selectedPanelId: selectedPanelId,
                isFullWidthTabMode: pane.isFullWidthTabMode
            ))
        case .split(let split):
            let first = pruning(split.first, keeping: panelIdsToKeep)
            let second = pruning(split.second, keeping: panelIdsToKeep)
            switch (first, second) {
            case (.some(let first), .some(let second)):
                return .split(SessionSplitLayoutSnapshot(
                    orientation: split.orientation,
                    dividerPosition: split.dividerPosition,
                    first: first,
                    second: second
                ))
            case (.some(let first), .none): return first
            case (.none, .some(let second)): return second
            case (.none, .none): return nil
            }
        }
    }

    static func orderedPanelIds(in node: SessionWorkspaceLayoutSnapshot) -> [UUID] {
        switch node {
        case .pane(let pane): return pane.panelIds
        case .split(let split):
            return orderedPanelIds(in: split.first) + orderedPanelIds(in: split.second)
        }
    }

    @MainActor
    static func applyDividerPositions(
        _ snapshot: SessionWorkspaceLayoutSnapshot,
        to controller: BonsplitController
    ) {
        applyDividerPositions(
            snapshotNode: snapshot,
            liveNode: controller.treeSnapshot(),
            controller: controller
        )
    }

    @MainActor
    private static func capture(
        node: ExternalTreeNode,
        controller: BonsplitController,
        panelIdsByTabId: [UUID: UUID]
    ) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .pane(let pane):
            let panelIds = pane.tabs.compactMap { tab in
                UUID(uuidString: tab.id).flatMap { panelIdsByTabId[$0] }
            }
            let selectedPanelId = pane.selectedTabId
                .flatMap(UUID.init(uuidString:))
                .flatMap { panelIdsByTabId[$0] }
            return .pane(SessionPaneLayoutSnapshot(
                panelIds: panelIds,
                selectedPanelId: selectedPanelId,
                isFullWidthTabMode: UUID(uuidString: pane.id).map {
                    controller.isFullWidthTabMode(inPane: PaneID(id: $0))
                }
            ))
        case .split(let split):
            return .split(SessionSplitLayoutSnapshot(
                orientation: split.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                dividerPosition: split.dividerPosition,
                first: capture(
                    node: split.first,
                    controller: controller,
                    panelIdsByTabId: panelIdsByTabId
                ),
                second: capture(
                    node: split.second,
                    controller: controller,
                    panelIdsByTabId: panelIdsByTabId
                )
            ))
        }
    }

    @MainActor
    private static func applyDividerPositions(
        snapshotNode: SessionWorkspaceLayoutSnapshot,
        liveNode: ExternalTreeNode,
        controller: BonsplitController
    ) {
        guard case .split(let snapshotSplit) = snapshotNode,
              case .split(let liveSplit) = liveNode else { return }
        if let splitId = UUID(uuidString: liveSplit.id) {
            _ = controller.setDividerPosition(
                CGFloat(snapshotSplit.dividerPosition),
                forSplit: splitId,
                fromExternal: true
            )
        }
        applyDividerPositions(
            snapshotNode: snapshotSplit.first,
            liveNode: liveSplit.first,
            controller: controller
        )
        applyDividerPositions(
            snapshotNode: snapshotSplit.second,
            liveNode: liveSplit.second,
            controller: controller
        )
    }
}
