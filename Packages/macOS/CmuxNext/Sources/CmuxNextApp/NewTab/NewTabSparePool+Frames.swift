import AppKit
import CmuxNextAgentPane
import CmuxNextLayout

/// Pane geometry and ownership supplied to AgentPane's parked-renderer lifecycle.
extension NewTabSparePool {
    func fitParked() {
        schedulePrepare()
        spareFrames.fit(parking: parking, size: targetPaneSize, opening: refills.isOpening,
                        views: slot.all, snapshot: snapshotParked)
    }

    func paneLayoutDidChange(in window: NSWindow?) {
        guard let window, window === target, parking.superview != nil else { return }
        let layout = services.windows.controllers.first { $0.window === window }?.content?.layoutView
        if layout?.isInLayoutMotion == true { spareFrames.cancel() }
        if targetIdentity != spareFrames.preparedFor { schedulePrepare() }
        layout?.whenSettled("NewTabSparePool.fit", after: Self.fitSettle, on: fits) { [weak self] in self?.fitParked() }
    }

    func snapshotParked(_ view: AgentPaneView) {
        spareFrames.snapshot(view, parking: parking, covers: covers,
                             parked: { [weak self] page in page.superview === self?.parking && self?.slot.all.contains { $0 === page } == true },
                             context: { [weak self, weak view] in self?.prefetchContext(for: view) },
                             invalidated: { [weak self] in self?.paneLayoutDidChange(in: self?.target) })
    }

    private func prefetchContext(for view: AgentPaneView?) -> AgentPaneNewTabSpareFrames.Context? {
        guard !refills.isOpening, let view, view === slot.peek, let pane = targetPane,
              pane.workspace?.layoutView.isInLayoutMotion != true else { return nil }
        return .init(identity: targetIdentity ?? [], full: pane.newTabContentSize,
                     splits: [PaneDropZone.right, .bottom].compactMap { pane.newTabSplitContentSize(zone: $0) })
    }

}

extension PaneController: NewTabPaneGeometrySource {
    var newTabPaneView: NSView { view }
    var newTabLayout: LayoutRootView? { workspace?.layoutView }
    var newTabHidesTabBar: Bool { hidesTabBar || isAppPane }
}
