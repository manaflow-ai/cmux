import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDesign
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
        prefetchToken = nil
        prefetchDeadline.cancel()
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
            prefetchToken = nil
            prefetchDeadline.cancel()
        }
        if targetIdentity != preparedFor { schedulePrepare() }
        services.windows.controllers.first { $0.window === window }?.content?.layoutView.whenSettled("NewTabSparePool.fit", after: Self.fitSettle, on: fits) { [weak self] in self?.fitParked() }
    }
    func snapshotParked(_ view: AgentPaneView) {
        guard prefetchToken == nil else { return }
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

    /// Native rendering glue: run Rust's exact-size plan on the ONE spare while parked, then restore it.
    func prefetchSplits(_ view: AgentPaneView) {
        guard prefetchToken == nil, !refills.isOpening, view.superview === parking, view === slot.peek,
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
        let token = UUID()
        prefetchToken = token
        // A lost compositor answer must not leave the Cmd-T spare at a split size indefinitely.
        prefetchDeadline.schedule(after: .seconds(3)) { @MainActor [weak self] in
            guard let self, self.prefetchToken == token else { return }
            self.fitParked()
        }
        covers.forget(view)
        func render(_ index: Int) {
            guard self.prefetchToken == token, view.superview === self.parking, view === self.slot.peek else { return }
            guard !self.refills.isOpening, self.targetIdentity == identity, self.targetPaneSize == full,
                  frames.generation == generation, view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance,
                  pane.workspace?.layoutView.isInLayoutMotion != true else {
                self.prefetchToken = nil
                self.prefetchDeadline.cancel()
                self.paneLayoutDidChange(in: self.target)
                return
            }
            guard index < plan.count else {
                self.prefetchToken = nil
                self.prefetchDeadline.cancel()
                self.snapshotParked(view)
                return
            }
            view.isHidden = false
            // Register before layout, so Chromium answers only a frame at this exact size.
            view.redraw.when(view) { [weak self, weak view] in
                guard let self, let view, self.prefetchToken == token, view.superview === self.parking else { return }
                view.redraw.rememberFrame(of: view, appearance: appearance) { render(index + 1) }
            }
            self.parking.fit(to: plan[index])
        }
        render(0)
    }

}
