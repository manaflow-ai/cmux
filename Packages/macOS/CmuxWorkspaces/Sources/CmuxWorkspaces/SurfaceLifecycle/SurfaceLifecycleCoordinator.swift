public import Foundation
public import Bonsplit
import CmuxPanes

/// Resolves a workspace's surface-lifecycle pane/index targets from the live
/// split tree: which pane a panel lives in, its tab index within that pane, the
/// right-side sibling pane for browser/file-preview placement, the top-right
/// reuse pane for sidebar PR opens, and the initial divider position applied to
/// a freshly created split.
///
/// These resolvers are lifted one-for-one from the legacy `Workspace`
/// Panel-Operations bodies (`paneId(forPanelId:)`, `indexInPane(forPanelId:)`,
/// `preferredRightSideTargetPane(fromPanelId:)`, `topRightBrowserReusePane()`,
/// `applyInitialSplitDividerPosition(_:sourcePaneId:newPaneId:)`). They are pure
/// reads over the bonsplit split tree plus one divider write; all live state is
/// reached through ``SurfaceLifecycleHosting`` so this type never holds the
/// app-target `Workspace`. The split-tree recursions
/// (`browserPathToPane`, `browserCollectPaneNodes`,
/// `browserCollectNormalizedPaneBounds`) come from `CmuxPanes`, exactly as the
/// legacy bodies already called them.
@MainActor
public final class SurfaceLifecycleCoordinator {
    private weak var host: (any SurfaceLifecycleHosting)?

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Attaches the workspace-side host the resolvers read through.
    public func attach(host: any SurfaceLifecycleHosting) {
        self.host = host
    }

    /// The pane id owning the panel, or `nil` when the panel maps to no surface
    /// or that surface is in no pane (legacy `Workspace.paneId(forPanelId:)`).
    public func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let host, let tabId = host.surfaceId(forPanelId: panelId) else { return nil }
        return host.allBonsplitPaneIds.first { paneId in
            host.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        }
    }

    /// The initial divider position applied to a freshly created split, mirroring
    /// the legacy private `Workspace.applyInitialSplitDividerPosition`. No-ops
    /// when `position` is `nil` or the source/new panes are not joined by a
    /// split.
    public func applyInitialSplitDividerPosition(
        _ position: CGFloat?,
        sourcePaneId: PaneID,
        newPaneId: PaneID
    ) {
        guard let host,
              let position,
              let splitId = host.treeSnapshot().splitIdJoiningPanes(
                sourcePaneId.id.uuidString,
                newPaneId.id.uuidString
              ) else { return }
        _ = host.applySplitDividerPosition(position, forSplit: splitId)
    }

    /// The tab index of the panel within its owning pane, or `nil` when the panel
    /// maps to no surface or is in no pane (legacy
    /// `Workspace.indexInPane(forPanelId:)`).
    public func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let host,
              let tabId = host.surfaceId(forPanelId: panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return host.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId })
    }

    /// The nearest right-side sibling pane for browser/file-preview placement,
    /// lifted one-for-one from `Workspace.preferredRightSideTargetPane`. The
    /// search is local to the source pane's ancestry in the split tree: the
    /// closest horizontal ancestor where the source is in the first (left) branch.
    public func preferredRightSideTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let host, let sourcePane = paneId(forPanelId: panelId) else { return nil }
        let sourcePaneId = sourcePane.id.uuidString
        let tree = host.treeSnapshot()
        guard let path = tree.browserPathToPane(targetPaneId: sourcePaneId) else { return nil }

        let layout = host.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.branch == .first else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            crumb.split.second.browserCollectPaneNodes(into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = host.allBonsplitPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    /// The top-right pane in the current split tree, lifted one-for-one from
    /// `Workspace.topRightBrowserReusePane`. When a workspace is already split,
    /// sidebar PR opens reuse an existing pane instead of creating more right
    /// splits.
    public func topRightBrowserReusePane() -> PaneID? {
        guard let host else { return nil }
        let paneIds = host.allBonsplitPaneIds
        guard paneIds.count > 1 else { return nil }

        let paneById = Dictionary(uniqueKeysWithValues: paneIds.map { ($0.id.uuidString, $0) })
        var paneBounds: [String: CGRect] = [:]
        host.treeSnapshot().browserCollectNormalizedPaneBounds(
            availableRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            into: &paneBounds
        )

        guard !paneBounds.isEmpty else {
            return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
        }

        let epsilon = 0.000_1
        let rightMostX = paneBounds.values.map(\.maxX).max() ?? 0

        let sortedCandidates = paneBounds
            .filter { _, rect in abs(rect.maxX - rightMostX) <= epsilon }
            .sorted { lhs, rhs in
                if abs(lhs.value.minY - rhs.value.minY) > epsilon {
                    return lhs.value.minY < rhs.value.minY
                }
                if abs(lhs.value.minX - rhs.value.minX) > epsilon {
                    return lhs.value.minX > rhs.value.minX
                }
                return lhs.key < rhs.key
            }

        for candidate in sortedCandidates {
            if let pane = paneById[candidate.key] {
                return pane
            }
        }

        return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }

    // MARK: - Browser profile resolution

    /// Records `profileID` as the workspace's preferred browser profile when it
    /// names a currently-defined profile, clearing the preference when `nil`.
    /// Faithful lift of `Workspace.setPreferredBrowserProfileID(_:)`: a `nil`
    /// argument clears unconditionally, a non-`nil` argument that no longer maps
    /// to a defined profile is ignored, and only a valid id is stored. The
    /// preferred-id storage lives on the workspace (the property is
    /// `private(set)`), so the write goes through
    /// ``SurfaceLifecycleHosting/surfaceLifecycleSetPreferredBrowserProfileID(_:)``.
    public func setPreferredBrowserProfileID(_ profileID: UUID?) {
        guard let host else { return }
        guard let profileID else {
            host.surfaceLifecycleSetPreferredBrowserProfileID(nil)
            return
        }
        guard host.surfaceLifecycleProfileDefinitionExists(id: profileID) else { return }
        host.surfaceLifecycleSetPreferredBrowserProfileID(profileID)
    }

    /// The browser profile id a freshly created browser surface should adopt,
    /// lifted one-for-one from `Workspace.resolvedNewBrowserProfileID`. The tiers,
    /// in order: an explicit `preferredProfileID` that still names a defined
    /// profile; the profile of an existing browser panel at `sourcePanelId` when
    /// that profile is still defined; the workspace's stored preferred profile
    /// when it is still defined; finally the store's effective last-used profile.
    /// Each non-final tier is gated on the profile still being defined, exactly as
    /// the legacy body's `BrowserProfileStore` lookups were.
    public func resolvedNewBrowserProfileID(
        preferredProfileID: UUID? = nil,
        sourcePanelId: UUID? = nil
    ) -> UUID? {
        guard let host else { return nil }
        if let preferredProfileID,
           host.surfaceLifecycleProfileDefinitionExists(id: preferredProfileID) {
            return preferredProfileID
        }
        if let sourcePanelId,
           let sourceProfileID = host.surfaceLifecycleSourcePanelProfileID(panelId: sourcePanelId),
           host.surfaceLifecycleProfileDefinitionExists(id: sourceProfileID) {
            return sourceProfileID
        }
        if let preferred = host.surfaceLifecyclePreferredBrowserProfileID,
           host.surfaceLifecycleProfileDefinitionExists(id: preferred) {
            return preferred
        }
        return host.surfaceLifecycleEffectiveLastUsedProfileID
    }
}
