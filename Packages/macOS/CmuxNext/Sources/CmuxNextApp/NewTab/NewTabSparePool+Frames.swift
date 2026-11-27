import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextDaemonService
import CmuxNextLayout
import CmuxNextPages

/// Cached New Tab covers and exact-size preparation on the single parked renderer.
extension NewTabSparePool {
    /// The size a Cmd-T tab in `pane` shows at: the pane less its tab bar, also where a browser's
    /// header band holds the bar now (the band goes with the browser).
    static func newTabContentSize(in pane: PaneController) -> NSSize {
        let scale = pane.view.window?.backingScaleFactor ?? 2
        let strip = pane.hidesTabBar || pane.isAppPane ? 0 : PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        return NSSize(width: pane.view.bounds.width, height: max(0, pane.view.bounds.height - strip))
    }

    /// Sizes the parking view and the spare in it to the target pane now, laid out, when it is parked in a window.
    func fitParked() {
        prefetcher.cancel()
        guard let content = parking.superview else { return }
        let size = targetPaneSize ?? content.bounds.size
        schedulePrepare()
        guard parking.frame != PageOffscreenParking.frame(in: content.bounds, size: size) else {
            if !refills.isOpening { slot.all.filter { $0.redraw.newTabFrameCaptureChanged == nil }.forEach(snapshotParked) }
            return
        }
        BenchSpans.measure("pool.fit") { parking.fit(to: size) }
        if !refills.isOpening { slot.all.forEach(snapshotParked) }
    }

    /// A pane of `window` changed size, or its focus or tab moved: the spare draws the context Cmd-T there gives and takes the
    /// pane's size in one background fit once the sizes settled (``fitSettle``) and the layout is still (`whenSettled`).
    func paneLayoutDidChange(in window: NSWindow?) {
        guard let window, window === target, parking.superview != nil else { return }
        if services.windows.controllers.first(where: { $0.window === window })?.content?.layoutView.isInLayoutMotion == true {
            prefetcher.cancel()
        }
        if targetIdentity != preparedFor { schedulePrepare() }
        services.windows.controllers.first { $0.window === window }?.content?.layoutView.whenSettled("NewTabSparePool.fit", after: Self.fitSettle, on: fits) { [weak self] in self?.fitParked() }
    }
    func snapshotParked(_ view: AgentPaneView) {
        guard !prefetcher.active else { return }
        covers.capture(view, parked: { [weak self] page in page.superview === self?.parking && self?.slot.all.contains { $0 === page } == true }) { [weak self, weak view] in
            if let view { self?.prefetchSplits(view) }
        }
    }

    /// The same geometry that a split's drop preview and even-sizing commit use; no half-size guess.
    static func splitContentSize(in pane: PaneController, zone: PaneDropZone) -> NSSize? {
        guard var size = pane.workspace?.layoutView.newSplitPaneSize(splitting: pane.layoutPaneID, zone: zone) else { return nil }
        let full = newTabContentSize(in: pane)
        size.height = max(0, size.height - (pane.view.bounds.height - full.height))
        return size
    }

    /// Divider insertion uses its planned ratio instead of the ordinary half/even split.
    static func dividerContentSize(in pane: PaneController, insertion: DividerInsertion) -> NSSize? {
        guard let change = insertion.sizing.first,
              let size = pane.workspace?.layoutView.newDividerPaneSize(splitting: change.split, ratio: change.ratio) else { return nil }
        let full = newTabContentSize(in: pane)
        return NSSize(width: size.width, height: max(0, size.height - (pane.view.bounds.height - full.height)))
    }

    /// Native rendering glue: run Rust's exact-size plan on the ONE spare while parked, then restore it.
    func prefetchSplits(_ view: AgentPaneView) {
        guard !prefetcher.active, !refills.isOpening, view.superview === parking, view === slot.peek,
              let pane = targetPane, pane.workspace?.layoutView.isInLayoutMotion != true, view.model.hasPainted else { return }
        let full = Self.newTabContentSize(in: pane), identity = targetIdentity
        let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let frames = AgentPaneNewTabFrame.shared, generation = frames.generation
        let sizes = [PaneDropZone.right, .bottom].compactMap { Self.splitContentSize(in: pane, zone: $0) }
        let cached = sizes.filter { frames.image(size: $0, appearance: appearance) != nil }
        let plan = NewPlacementPlan.newTabPrefetch(parked: full, splits: sizes, cached: cached)
        let attempt: [AnyHashable] = [ObjectIdentifier(view), generation, full.width, full.height, appearance?.rawValue ?? ""] + (identity ?? []) + sizes.flatMap { [AnyHashable($0.width), AnyHashable($0.height)] }
        guard !plan.isEmpty, prefetchAttempt != attempt, frames.image(size: full, appearance: appearance) != nil else { return }
        prefetchAttempt = attempt
        prefetcher.start(
            view: view,
            parking: parking,
            covers: covers,
            frames: frames,
            appearance: appearance,
            generation: generation,
            full: full,
            plan: plan,
            valid: { [weak self, weak view, weak pane] in
                guard let self, let view, let pane else { return false }
                return !self.refills.isOpening &&
                    view === self.slot.peek &&
                    view.superview === self.parking &&
                    self.targetIdentity == identity &&
                    self.targetPaneSize == full &&
                    pane.workspace?.layoutView.isInLayoutMotion != true
            },
            finished: { [weak self, weak view] in
                guard let self, let view else { return }
                if view.superview === self.parking, view === self.slot.peek {
                    self.snapshotParked(view)
                }
            },
            invalidated: { [weak self] in
                guard let self else { return }
                self.paneLayoutDidChange(in: self.target)
            })
    }

}
