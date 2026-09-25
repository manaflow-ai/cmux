import AppKit
import Bonsplit

// MARK: - Split-transaction pane geometry

extension Workspace {
    /// Moves the terminals of a pane bonsplit just split to their projected
    /// post-split frames inside the split transaction.
    ///
    /// The tree update is synchronous, but SwiftUI re-hosts the split pane's
    /// subtree later, and the terminal portal only learns geometry from the
    /// re-created anchors. Until they bind, the source terminal (a transparent
    /// glyph layer above SwiftUI) would keep its pre-split frame and paint over
    /// the new pane's tab bar and content
    /// (https://github.com/manaflow-ai/cmux/issues/13387). Projecting the
    /// model's own split geometry here puts the resize in the same
    /// CoreAnimation commit as the new chrome; the anchors' real geometry
    /// replaces it when they bind.
    ///
    /// Every split entrypoint funnels through bonsplit's `didSplitPane`
    /// delegate call (shortcut, command palette, CLI, tab-bar buttons,
    /// drag-to-split), so the same projection covers the source terminal and a
    /// dragged terminal that now sits in the new pane. Programmatic splits call
    /// again after imposing their initial divider position; the projection
    /// re-derives from the frame the terminal had before the transaction.
    ///
    /// The projection is keyed by the split node it was derived from. The
    /// anchors take geometry back when they re-layout or bind; a split that
    /// leaves the model before that (closed again before SwiftUI rendered it)
    /// releases its projection through
    /// ``releaseProvisionalSplitPaneGeometryForRemovedSplits()``.
    func applyProvisionalSplitPaneGeometry(originalPane: PaneID, newPane: PaneID) {
        guard isPortalRenderingEnabled, layoutMode != .canvas,
              let split = splitNodeJoiningPaneIds(
                originalPane.id.uuidString,
                newPane.id.uuidString,
                in: bonsplitController.treeSnapshot()
              ),
              let transactionID = UUID(uuidString: split.id) else { return }
        let rootSplitInfo: (newPaneIsFirst: Bool, existingTree: ExternalTreeNode)? = {
            switch split.first {
            case .pane(let pane) where pane.id == newPane.id.uuidString:
                return (true, split.second)
            default:
                guard case .pane(let pane) = split.second,
                      pane.id == newPane.id.uuidString else { return nil }
                return (false, split.first)
            }
        }()
        if let rootSplitInfo, case .split = rootSplitInfo.existingTree {
            applyProvisionalRootSplitGeometry(
                split: split,
                transactionID: transactionID,
                existingTree: rootSplitInfo.existingTree,
                newPaneIsFirst: rootSplitInfo.newPaneIsFirst,
                newPane: newPane
            )
            return
        }
        let originalTabs = bonsplitController.tabs(inPane: originalPane)
        let newTabs = bonsplitController.tabs(inPane: newPane)
        let originalTerminals = presentedTerminalHostedViews(forTabs: originalTabs)
        let newTerminals = presentedTerminalHostedViews(forTabs: newTabs)
        // The base is a terminal that was presented in the original pane. When
        // the pane's only tab was dragged out, that terminal now sits in the
        // new pane and the original holds nothing but a placeholder.
        let originalPaneHasRealSurface = originalTabs.contains { panelIdFromSurfaceId($0.id) != nil }
        guard let base = originalTerminals.first ?? (originalPaneHasRealSurface ? nil : newTerminals.first),
              let baseFrame = TerminalWindowPortalRegistry.provisionalBaseFrameInWindow(for: base)
                ?? Self.frameInWindow(of: base) else { return }

        let configuration = bonsplitController.configuration
        // A non-programmatic split whose new pane already holds tabs moved
        // them there from the original pane.
        let movedTabCount = isProgrammaticSplit ? 0 : newTabs.count
        let request = SplitPaneGeometryProjection.Request(
            orientation: split.orientation == SplitOrientation.horizontal.rawValue ? .horizontal : .vertical,
            sourceIsFirst: splitTreeContainsPane(originalPane.id.uuidString, in: split.first),
            dividerPosition: CGFloat(split.dividerPosition),
            imposedFirstExtent: split.imposedFirstExtent.map { CGFloat($0) },
            sourceContentFrame: baseFrame,
            baseShowsTabBar: configuration.tabBarVisibility.showsTabBar(
                tabCount: originalTabs.count + movedTabCount
            ),
            sourceShowsTabBar: configuration.tabBarVisibility.showsTabBar(tabCount: originalTabs.count),
            newPaneShowsTabBar: configuration.tabBarVisibility.showsTabBar(tabCount: max(newTabs.count, 1))
        )
        guard let projection = SplitPaneGeometryProjection.project(
            request,
            chrome: SplitPaneGeometryProjection.Chrome(configuration: configuration)
        ) else { return }

        for hostedView in originalTerminals {
            TerminalWindowPortalRegistry.applyProvisionalPaneFrame(
                projection.sourceContentFrame, for: hostedView, transactionID: transactionID
            )
        }
        for hostedView in newTerminals {
            TerminalWindowPortalRegistry.applyProvisionalPaneFrame(
                projection.newPaneContentFrame, for: hostedView, transactionID: transactionID
            )
        }
#if DEBUG
        cmuxDebugLog(
            "split.provisionalGeometry original=\(originalPane.id.uuidString.prefix(5)) " +
            "new=\(newPane.id.uuidString.prefix(5)) orientation=\(split.orientation) " +
            "sourceIsFirst=\(request.sourceIsFirst ? 1 : 0) divider=\(String(format: "%.3f", split.dividerPosition)) " +
            "imposed=\(split.imposedFirstExtent.map { String(format: "%.1f", $0) } ?? "nil") " +
            "base=\(portalDebugFrame(baseFrame)) source=\(portalDebugFrame(projection.sourceContentFrame)) " +
            "newPane=\(portalDebugFrame(projection.newPaneContentFrame)) " +
            "sourceViews=\(originalTerminals.count) newViews=\(newTerminals.count)"
        )
#endif
    }

    /// Projects every terminal in an existing root tree into its new root-child frame.
    private func applyProvisionalRootSplitGeometry(
        split: ExternalSplitNode,
        transactionID: UUID,
        existingTree: ExternalTreeNode,
        newPaneIsFirst: Bool,
        newPane: PaneID
    ) {
        let existingPaneIds = bonsplitController.allPaneIds.filter {
            splitTreeContainsPane($0.id.uuidString, in: existingTree)
        }
        let existingTerminals = existingPaneIds.flatMap { paneId in
            presentedTerminalHostedViews(forTabs: bonsplitController.tabs(inPane: paneId))
        }
        let baseFrames = existingTerminals.compactMap { hostedView -> (GhosttySurfaceScrollView, NSRect)? in
            let frame = TerminalWindowPortalRegistry.provisionalBaseFrameInWindow(for: hostedView)
                ?? Self.frameInWindow(of: hostedView)
            return frame.map { (hostedView, $0) }
        }
        guard let treeFrame = baseFrames.map { $0.1 }.reduce(nil, { partial, frame in
            partial.map { $0.union(frame) } ?? frame
        }) else { return }

        let newTabs = bonsplitController.tabs(inPane: newPane)
        let request = SplitPaneGeometryProjection.Request(
            orientation: split.orientation == SplitOrientation.horizontal.rawValue ? .horizontal : .vertical,
            sourceIsFirst: !newPaneIsFirst,
            dividerPosition: CGFloat(split.dividerPosition),
            imposedFirstExtent: split.imposedFirstExtent.map { CGFloat($0) },
            sourceContentFrame: treeFrame,
            baseShowsTabBar: false,
            sourceShowsTabBar: false,
            newPaneShowsTabBar: bonsplitController.configuration.tabBarVisibility.showsTabBar(
                tabCount: max(newTabs.count, 1)
            )
        )
        guard let projection = SplitPaneGeometryProjection.project(
            request,
            chrome: SplitPaneGeometryProjection.Chrome(configuration: bonsplitController.configuration)
        ) else { return }

        for (hostedView, frame) in baseFrames {
            TerminalWindowPortalRegistry.applyProvisionalPaneFrame(
                Self.map(frame, from: treeFrame, to: projection.sourceContentFrame),
                for: hostedView,
                transactionID: transactionID
            )
        }
        let newTerminals = presentedTerminalHostedViews(forTabs: newTabs)
        for hostedView in newTerminals {
            TerminalWindowPortalRegistry.applyProvisionalPaneFrame(
                projection.newPaneContentFrame,
                for: hostedView,
                transactionID: transactionID
            )
        }
#if DEBUG
        cmuxDebugLog(
            "split.provisionalGeometry root=1 existingPanes=\(existingPaneIds.count) " +
            "new=\(newPane.id.uuidString.prefix(5)) orientation=\(split.orientation) " +
            "sourceIsFirst=\(request.sourceIsFirst ? 1 : 0) divider=\(String(format: "%.3f", split.dividerPosition)) " +
            "tree=\(portalDebugFrame(treeFrame)) source=\(portalDebugFrame(projection.sourceContentFrame)) " +
            "newPane=\(portalDebugFrame(projection.newPaneContentFrame)) sourceViews=\(baseFrames.count) newViews=\(newTerminals.count)"
        )
#endif
    }

    /// Hands geometry back to the anchors of projections whose split no
    /// longer exists in the model: a split closed again before SwiftUI
    /// rendered it, or a layout replaced wholesale. Runs from bonsplit's
    /// structural delegate events, which follow the tree mutation.
    func releaseProvisionalSplitPaneGeometryForRemovedSplits() {
        let liveSplitIDs = Self.splitNodeIDs(in: bonsplitController.treeSnapshot())
        TerminalWindowPortalRegistry.releaseProvisionalPaneGeometry(inWorkspace: id) { transactionID in
            !liveSplitIDs.contains(transactionID)
        }
    }

    private static func splitNodeIDs(in node: ExternalTreeNode) -> Set<UUID> {
        switch node {
        case .pane:
            return []
        case .split(let split):
            var ids = splitNodeIDs(in: split.first).union(splitNodeIDs(in: split.second))
            if let id = UUID(uuidString: split.id) { ids.insert(id) }
            return ids
        }
    }

    private func presentedTerminalHostedViews(forTabs tabs: [Bonsplit.Tab]) -> [GhosttySurfaceScrollView] {
        tabs.compactMap { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let panel = terminalPanel(for: panelId),
                  // A multi-pane remote-tmux window-tab is rendered by its
                  // mirror view, which owns that panel's portal geometry.
                  remoteTmuxWindowMirrors[panelId] == nil else { return nil }
            let hostedView = panel.hostedView
            return TerminalWindowPortalRegistry.isPresented(hostedView) ? hostedView : nil
        }
    }

    private static func frameInWindow(of view: NSView) -> NSRect? {
        guard view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    private static func map(_ frame: NSRect, from source: NSRect, to target: NSRect) -> NSRect {
        guard source.width > 0, source.height > 0 else { return target }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        return NSRect(
            x: target.minX + (frame.minX - source.minX) * scaleX,
            y: target.minY + (frame.minY - source.minY) * scaleY,
            width: frame.width * scaleX,
            height: frame.height * scaleY
        )
    }
}
