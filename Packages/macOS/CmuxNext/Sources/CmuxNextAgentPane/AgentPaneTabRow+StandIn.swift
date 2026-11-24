import AppKit
public import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups

/// The pane's native stand-in for a Chromium chat's tools while a resize drag moves its tab row (``PaneTabRowStandIn``;
/// Leo 2026-11-24: "it's unsatisfying for the buttons to track the dragging of the pane split dividers so poorly. it
/// lags, it doesn't follow in lockstep"). The page draws its tools in another process, some frames after the pane takes
/// its size; the pane's strip and toolbar move in the drag's own commit. From the drag's first move (a divider, a
/// window's live resize: ``PaneResizeGestureFollowing``) the pane draws the tools the page published
/// (`pane.tabRowTools.set`, offered as `standInRowTools`) in an opaque band over the page's own, and the band goes in
/// the commit after the page drew at the size the drag ended at. Both showing for a frame is fine (the band is opaque);
/// neither showing never happens. `ChromeTunables.nativeRowTools` on draws the tools natively all the time instead.
extension AgentPaneTabRow {
    /// The band to draw now, in the chat view's coordinates; nil while there is none.
    public var standIn: PaneTabRowStandIn? {
        guard let standInBand, let standInFill, standingIn, !standInTools.isEmpty, let height = shape?.height else { return nil }
        return PaneTabRowStandIn(frame: standInBand, rim: min(Self.rimHeight, height), tools: standInTools, fill: standInFill)
    }

    /// The tools the page published for the stand-in; a change while it shows lays the pane out again.
    func setStandInTools(_ tools: [PaneTabRowTool]) {
        guard tools != standInTools else { return }
        standInTools = tools
        if standingIn { onChange?() }
    }

    /// The band in a row `width` wide (top-left origin) whose tools take `tools` points before `trailingInset`: from the
    /// leftmost x the tools took since the stand-in began to the row's trailing end. The page's tools lag the pane by a
    /// few frames and a drag can turn back, so the band keeps every x they may still be drawn at, not just the drag's
    /// start and now. Nil with no stand-in.
    func standInBand(width: CGFloat, height: CGFloat, trailingInset: CGFloat, tools: CGFloat) -> CGRect? {
        guard standingIn, standInFill != nil, !standInTools.isEmpty else { return nil }
        let room = max(0, width - trailingInset)
        let x = room - min(max(0, tools), room / 2)
        let left = min(standInLeft ?? x, x)
        standInLeft = left
        let band = CGRect(x: max(0, left), y: 0, width: max(0, room - max(0, left)), height: height)
        return band.isEmpty ? nil : band
    }

    /// A resize drag began: the pane draws the tools from this layout on, filled with `fill` (the row's hole fill, or the
    /// page's surface). Only for a page offered the stand-in, which publishes its tools. Lays the pane out now, in the
    /// drag's first frame.
    func beginStandIn(fill: CGColor?) {
        standInEpoch &+= 1
        guard offeredStandIn == true, let fill else { return }
        if !standingIn { standInLeft = nil }
        standingIn = true
        standInFill = fill
        onChange?()
    }

    /// The drag ended: the band goes once `drawn` answers (the page drew at the size it ended at). A drag begun
    /// meanwhile keeps it, and a second answer does nothing.
    func endStandIn(after drawn: (@escaping () -> Void) -> Void) {
        guard standingIn else { return }
        standInEpoch &+= 1
        let epoch = standInEpoch
        drawn { [weak self] in
            guard let self, self.standInEpoch == epoch, self.standingIn else { return }
            self.standingIn = false
            self.standInLeft = nil
            self.standInBand = nil
            self.onChange?()
        }
    }
}

/// A chat hears a person's resize drags (``PaneResizeGestureFollowing``, found in its pane's subtree; no observer of its
/// own) to stand in for its tools (``AgentPaneTabRow/standIn``).
extension AgentPaneView: PaneResizeGestureFollowing {
    public func paneResizeGestureDidChange(active: Bool) {
        let row = model.tabRow
        guard active else {
            row.endStandIn { [weak self] done in self?.afterDrawnAtFinalSize(done) ?? done() }
            return
        }
        row.beginStandIn(fill: row.holeFill ?? performWithTheme {
            let color = AgentPaneTheme.pageBackground(themeTokens, surface: surfaceKind)
            return color.alpha > 0 ? color.cgColor : nil
        })
    }

    /// Runs `done` once the page drew a frame at the size it shows at now (its tools are where the band puts them), at
    /// most `limit` from now (a hung page still gives its row back).
    private func afterDrawnAtFinalSize(limit: Duration = .seconds(1), _ done: @escaping () -> Void) {
        // `done` may run twice (the page's answer after the deadline): the row's end ignores the second.
        let deadline = DemandTimer(owner: "agentPane.tabRowStandIn.deadline")
        deadline.schedule(after: limit) { @MainActor in
            withExtendedLifetime(deadline) {}
            done()
        }
        let finish = { deadline.cancel(); done() }
        guard let page else { return finish() }
        let size = page.frame.size
        guard size.width > 0, size.height > 0 else { return redraw.afterNextFrame(finish) }
        page.afterFrame(at: size, finish)
    }
}
