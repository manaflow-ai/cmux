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
    func applyProvisionalSplitPaneGeometry(originalPane: PaneID, newPane: PaneID) {
        guard isPortalRenderingEnabled, layoutMode != .canvas,
              let split = splitNodeJoiningPaneIds(
                originalPane.id.uuidString,
                newPane.id.uuidString,
                in: bonsplitController.treeSnapshot()
              ) else { return }
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
            TerminalWindowPortalRegistry.applyProvisionalPaneFrame(projection.sourceContentFrame, for: hostedView)
        }
        for hostedView in newTerminals {
            TerminalWindowPortalRegistry.applyProvisionalPaneFrame(projection.newPaneContentFrame, for: hostedView)
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
}
