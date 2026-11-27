import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextDaemonService
import CmuxNextLayout
import CmuxNextPages

/// App wiring for the parked renderer; frame lifecycle lives in AgentPane.
extension NewTabSparePool {
    static func newTabContentSize(in pane: PaneController) -> NSSize { let scale = pane.view.window?.backingScaleFactor ?? 2; let strip = pane.hidesTabBar || pane.isAppPane ? 0 : PaneChromeMetrics.current.resolvedStripHeight(scale: scale); return NSSize(width: pane.view.bounds.width, height: max(0, pane.view.bounds.height - strip)) }
    func fitParked() { spareFrames.cancel(); guard let content = parking.superview else { return }; let size = targetPaneSize ?? content.bounds.size; schedulePrepare(); BenchSpans.measure("pool.fit") { spareFrames.fit(parking: parking, content: content, size: size, opening: refills.isOpening, views: slot.all, snapshot: snapshotParked) } }
    func paneLayoutDidChange(in window: NSWindow?) { guard let window, window === target, parking.superview != nil else { return }; if services.windows.controllers.first(where: { $0.window === window })?.content?.layoutView.isInLayoutMotion == true { spareFrames.cancel() }; if targetIdentity != preparedFor { schedulePrepare() }; services.windows.controllers.first { $0.window === window }?.content?.layoutView.whenSettled("NewTabSparePool.fit", after: Self.fitSettle, on: fits) { [weak self] in self?.fitParked() } }
    func snapshotParked(_ view: AgentPaneView) { spareFrames.snapshot(view, parking: parking, covers: covers, parked: { [weak self] in view.superview === self?.parking && self?.slot.all.contains { $0 === view } == true }, after: { [weak self, weak view] in if let view { self?.prefetchSplits(view) } }) }
    static func splitContentSize(in pane: PaneController, zone: PaneDropZone) -> NSSize? { guard var size = pane.workspace?.layoutView.newSplitPaneSize(splitting: pane.layoutPaneID, zone: zone) else { return nil }; let full = newTabContentSize(in: pane); size.height = max(0, size.height - (pane.view.bounds.height - full.height)); return size }
    static func dividerContentSize(in pane: PaneController, insertion: DividerInsertion) -> NSSize? { guard let change = insertion.sizing.first, let size = pane.workspace?.layoutView.newDividerPaneSize(splitting: change.split, ratio: change.ratio) else { return nil }; let full = newTabContentSize(in: pane); return NSSize(width: size.width, height: max(0, size.height - (pane.view.bounds.height - full.height))) }
    func prefetchSplits(_ view: AgentPaneView) {
        guard !spareFrames.active, !refills.isOpening, view.superview === parking, view === slot.peek, let pane = targetPane, pane.workspace?.layoutView.isInLayoutMotion != true, view.model.hasPainted else { return }
        let full = Self.newTabContentSize(in: pane), identity = targetIdentity, frames = AgentPaneNewTabFrame.shared, appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), generation = frames.generation, sizes = [PaneDropZone.right, .bottom].compactMap { Self.splitContentSize(in: pane, zone: $0) }, cached = sizes.filter { frames.image(size: $0, appearance: appearance) != nil }, plan = NewPlacementPlan.newTabPrefetch(parked: full, splits: sizes, cached: cached), attempt: [AnyHashable] = [ObjectIdentifier(view), generation, full.width, full.height, appearance?.rawValue ?? ""] + (identity ?? []) + sizes.flatMap { [AnyHashable($0.width), AnyHashable($0.height)] }
        spareFrames.prefetch(view: view, parking: parking, covers: covers, frames: frames, appearance: appearance, generation: generation, full: full, plan: plan, attempt: attempt, valid: { [weak self, weak view, weak pane] in guard let self, let view, let pane else { return false }; return !self.refills.isOpening && view === self.slot.peek && view.superview === self.parking && self.targetIdentity == identity && self.targetPaneSize == full && pane.workspace?.layoutView.isInLayoutMotion != true }, finished: { [weak self, weak view] in guard let self, let view else { return }; if view.superview === self.parking, view === self.slot.peek { self.snapshotParked(view) } }, invalidated: { [weak self] in guard let self else { return }; self.paneLayoutDidChange(in: self.target) })
    }
}
