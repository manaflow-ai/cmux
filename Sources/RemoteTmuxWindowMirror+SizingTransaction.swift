import AppKit
import CmuxRemoteSession
import CmuxTerminal
import Foundation

extension RemoteTmuxWindowMirror {
    /// Records the container's size (points) and backing scale — f's variable
    /// inputs, delivered by the view on mount and every geometry change.
    ///
    /// A size change also re-imposes the divider plan: rail fractions are a
    /// function of the container (``RemoteTmuxNativeSplitLayoutPlanner``), so a
    /// resize that stays inside one claim bucket — same claim, no
    /// `%layout-change` echo, no reconcile — would otherwise leave the tree
    /// scaling stale fractions proportionally, and a lopsided split can
    /// lose more than the pane slack and wrap. The old ideal-over-ideal
    /// fractions were container-independent, so no trigger existed here.
    func noteContainerSize(pointSize: CGSize, scale: CGFloat) {
        guard !isTornDown else { return }
        // Hidden tabs keep their last visible geometry. A hidden tab's
        // portal-hosted views have no window clamping them, so their
        // reported bounds are not the size anything renders at — and once
        // impositions inflate a hidden host (see imposeDividerPlan),
        // recording those bounds would poison the claim tmux hears when a
        // reconnect lets every window claim again. The one exception is the
        // very first measurement: a never-shown mirror must still record
        // its attach-time size so the initial claim can keep tmux off its
        // 80×24 default.
        guard isVisibleForSizing || containerSizePt == nil else { return }
        // Portal mount and teardown can report 0x0 or 1x1. Such a sample is
        // never sizing truth, including after a useful detached measurement:
        // accepting it would overwrite the pending reattach size.
        guard pointSize.width > 1, pointSize.height > 1 else { return }
        // A mirror's container cannot exceed the content area of the window
        // hosting it — that is a physical invariant, not a heuristic.
        // SwiftUI can hand this callback a content-derived size when some
        // ancestor briefly adopts a layout ideal (seen at fresh connect
        // with a starved pane: the container read the full DISPLAY width
        // while the app window was a third of it, so the claim spiked to
        // the display ceiling and tmux — correctly sizing to the real
        // window — never matched it, wedging forever). Clamp to the hosting
        // window's content width when a visible window holds the panes. A
        // later detached measurement is retained pending a trustworthy bound;
        // the first keeps the guarded display fallback required below.
        var pointSize = pointSize
        if let bound = visibleHostingContext()?.contentSize {
            pointSize.width = min(pointSize.width, bound.width)
            pointSize.height = min(pointSize.height, bound.height)
        } else if containerSizePt == nil {
            // Preserve the one-time no-host fallback: every hidden tmux
            // window must claim before selection or the first claim from a
            // sibling drops it to 80x24. The next hosted pass revalidates it.
            let widths = NSScreen.screens.map(\.visibleFrame.width)
            let heights = NSScreen.screens.map(\.visibleFrame.height)
            if let maxW = widths.max(), let maxH = heights.max(), maxW > 1, maxH > 1 {
                pointSize.width = min(pointSize.width, maxW)
                pointSize.height = min(pointSize.height, maxH)
            }
        } else {
            pendingContainerSizePt = pointSize
            pendingContainerScale = scale
            setNeedsSizingPass()
            return
        }
        pendingContainerSizePt = nil
        pendingContainerScale = nil
        #if DEBUG
        if pointSize.width > 3000 || pointSize.height > 3000 {
            let window = visibleHostingContext()?.window
            cmuxDebugLog(
                "remote.container.record @\(windowId)"
                    + " size=\(Int(pointSize.width))x\(Int(pointSize.height))"
                    + " panels=\(panelsByPaneId.count)"
                    + " win=\(window.map { "\(Int($0.contentLayoutRect.width))x\(Int($0.contentLayoutRect.height)) vis=\($0.isVisible ? 1 : 0) cls=\(String(describing: type(of: $0)))" } ?? "nil")"
            )
        }
        #endif
        containerSizePt = pointSize
        containerScale = scale
        setNeedsSizingPass()
    }

    /// Finds a trustworthy host from any pane whose portal is attached to a
    /// visible window. Dictionary order cannot decide which pane is mounted;
    /// every consumer uses this predicate so sizing and portal catch-up target
    /// the same host.
    func visibleHostingContext() -> (contentSize: CGSize, window: NSWindow?)? {
        if let size = hostingContentSizeSource?(), size.width > 1, size.height > 1 {
            return (size, nil)
        }
        if hostingContentSizeSource != nil { return nil }
        for panel in panelsByPaneId.values {
            let view = panel.hostedView
            guard view.isVisibleInUI, !view.isHidden, view.superview != nil,
                  let window = view.window, window.isVisible else { continue }
            let size = window.contentLayoutRect.size
            if size.width > 1, size.height > 1 { return (size, window) }
        }
        return nil
    }

    /// Ingests one sizing sample into the min-tracked pad constants.
    private func ingest(sample: TerminalSurfaceRawSizingSample) {
        guard sample.cellWidthPx > 0, sample.cellHeightPx > 0,
              sample.columns > 1, sample.rows > 1,
              let scale = sample.backingScale ?? containerScale, scale > 0
        else { return }
        let nonGridW = sample.surfaceWidthPx - sample.columns * sample.cellWidthPx
        let nonGridH = sample.surfaceHeightPx - sample.rows * sample.cellHeightPx
        if nonGridW >= 0 {
            minNonGridWidthPxByScale[scale] = min(minNonGridWidthPxByScale[scale] ?? nonGridW, nonGridW)
        }
        if nonGridH >= 0 {
            minNonGridHeightPxByScale[scale] = min(minNonGridHeightPxByScale[scale] ?? nonGridH, nonGridH)
        }
        let geometry = RemoteTmuxMirrorGeometry(
            cellWidthPx: sample.cellWidthPx,
            cellHeightPx: sample.cellHeightPx,
            surfacePadWidthPx: minNonGridWidthPxByScale[scale] ?? max(0, nonGridW),
            surfacePadHeightPx: minNonGridHeightPxByScale[scale] ?? max(0, nonGridH),
            scale: scale
        )
        if geometrySnapshot != geometry {
            geometrySnapshot = geometry
            setNeedsSizingPass()
        }
    }

    // MARK: The sizing transaction

    private func currentSizingInputs() -> SizingInputs {
        SizingInputs(
            baseLayout: layout,
            visibleLayout: visibleLayout,
            container: containerSizePt,
            scale: containerScale,
            geometry: geometrySnapshot,
            titleRowPlacement: tmuxTitleRowPlacement,
            visible: isVisibleForSizing
        )
    }

    /// The ONLY way sizing work is requested. Every trigger — container
    /// geometry, tmux layouts, calibration samples, visibility, title rows —
    /// updates its data and calls this; nothing runs layout directly. One
    /// coalesced pass drains on the next runloop turn, so a burst of events
    /// costs one pass, and an event that changes nothing costs none.
    func setNeedsSizingPass() {
        guard !isTornDown, !sizingPassScheduled else { return }
        sizingPassScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.performSizingPassNow()
        }
    }

    /// One transaction: claim, then plan and apply, exactly once, against a
    /// snapshot of the inputs. Events that fire DURING the pass (samples and
    /// geometry callbacks from our own applies included) can only update
    /// data and re-call setNeedsSizingPass — the flag is cleared before the
    /// work so they schedule a follow-up turn instead of re-entering. The
    /// follow-up compares inputs and stops when nothing changed: feedback
    /// converges by fixed point, bounded by real input changes, with no
    /// retry budgets and no event dedup anywhere.
    func performSizingPassNow() {
        sizingPassScheduled = false
        guard !isTornDown else { return }
        let intent = pendingSizingPassIntent
        let hostingContext = visibleHostingContext()
        let visibleHostingBound = hostingContext?.contentSize
        // Adopt a detached callback, or re-clamp a prior value, as soon as
        // any pane is visibly hosted. This pass is also the recovery path
        // when attachment itself does not emit another geometry callback.
        if let bound = visibleHostingBound {
            if var size = pendingContainerSizePt {
                size.width = min(size.width, bound.width)
                size.height = min(size.height, bound.height)
                containerSizePt = size
                containerScale = pendingContainerScale
                pendingContainerSizePt = nil
                pendingContainerScale = nil
            } else if var size = containerSizePt,
                      size.width > bound.width + 0.5 || size.height > bound.height + 0.5 {
                size.width = min(size.width, bound.width)
                size.height = min(size.height, bound.height)
                containerSizePt = size
            }
        }
        let inputs = currentSizingInputs()
        if inputs == lastCompletedSizingInputs { return }
        guard updateClientSize() else { return }
        // A visible transaction is not complete until its live host exists:
        // the claim may be sent while detached, but divider imposition and the
        // portal catch-up are the other half of the same transaction.
        guard !inputs.visible || hostingContext != nil else { return }
        pendingSizingPassIntent = .inputChange
        lastCompletedSizingInputs = inputs
        if inputs.visible {
            imposeDividerPlan(retryImposedExtents: intent == .constraintRecovery)
            // The imposition applies to bonsplit on the NEXT runloop turn
            // (coalesced), so the anchors move after this pass returns. The
            // portal syncs its hosted views from AppKit's async geometry
            // callbacks, which under churn can sample an anchor before its
            // imposed move or coalesce the catch-up away — leaving a hosted
            // view at a stale (wider) frame over its shrunk neighbor. Drive
            // the resync explicitly two turns out, after the apply has
            // landed: the transaction owns the geometry change, so it owns
            // telling the portal, rather than racing notifications.
            if let window = hostingContext?.window {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(
                    for: window, forceImmediate: false
                )
            }
        }
    }

    /// Marks native constraints unsettled so the next pass runs even with
    /// identical sizing inputs. Rebuilds, structural edits, appearance changes,
    /// and tab re-shows can all leave live split views without the prior plan.
    func setNeedsSizingPassIgnoringInputs() {
        guard !isTornDown else { return }
        pendingSizingPassIntent = .constraintRecovery
        lastCompletedSizingInputs = nil
        setNeedsSizingPass()
    }

    #if DEBUG
    /// One-shot per window: at container-suspect time, walk from a pane's
    /// view to the window logging each ancestor's class and width. The
    /// FIRST ancestor wider than the window names the view whose sizing
    /// rule still adopts a content-derived ideal.
    func debugDumpAncestorWidths() {
        guard !Self.dumpedAncestorChains.contains(windowId),
              let view = panelsByPaneId.values.first?.hostedView else { return }
        Self.dumpedAncestorChains.insert(windowId)
        let windowWidth = view.window?.contentLayoutRect.width ?? -1
        var node: NSView? = view
        var depth = 0
        while let current = node, depth < 60 {
            let width = Int(current.frame.width)
            let marker = CGFloat(width) > windowWidth + 1 ? " OVERSIZED" : ""
            cmuxDebugLog(
                "remote.container.chain @\(windowId) [\(depth)]"
                    + " \(String(describing: type(of: current))) w=\(width)\(marker)"
            )
            node = current.superview
            depth += 1
        }
        cmuxDebugLog("remote.container.chain @\(windowId) window=\(Int(windowWidth))")
    }
    #endif

    func handleSizingSample(_ sample: TerminalSurfaceRawSizingSample, paneId: Int) {
        guard !isTornDown else { return }
        ingest(sample: sample)
        lastRenderedGrids[paneId] = (cols: sample.columns, rows: sample.rows)
        #if DEBUG
        // The one line that makes "tests green, screen wrong" a grep instead
        // of a debugging session: whenever a surface settles on a grid that
        // disagrees with the span tmux assigned its pane, say so. Rendering
        // FEWER columns than assigned wraps every full-width line.
        if let leaf = renderedLayout.firstLeaf(withPaneId: paneId),
           sample.columns < leaf.width || sample.rows < leaf.height {
            cmuxDebugLog(
                "remote.grid.mismatch @\(windowId) pane=%\(paneId)"
                    + " rendered=\(sample.columns)x\(sample.rows)"
                    + " assigned=\(leaf.width)x\(leaf.height)"
            )
        }
        #endif
        setNeedsSizingPass()
    }

    /// Sweeps every pane's current sizing sample through ``ingest(sample:)``
    /// — the push path's calibration refresh for triggers that don't carry a
    /// sample of their own (container changes, structure changes).
    private func refreshGeometryConstants() {
        for panel in panelsByPaneId.values {
            guard let sample = panel.surface.rawSizingSample() else { continue }
            ingest(sample: sample)
        }
    }

    /// The measured render constants, or nil while no sample has arrived
    /// yet. A pure read of the stored snapshot (or the injected test
    /// source): consumers never touch live surfaces, so they can't observe
    /// half-applied resize state.
    func currentGeometry() -> RemoteTmuxMirrorGeometry? {
        if let geometrySource { return geometrySource() }
        return geometrySnapshot
    }

    /// Pushes this window's client size to tmux: f(container pixels, base
    /// structure, measured constants) via the connection's per-window form
    /// (dedup and reconnect reseed live there). Feed-forward by construction —
    /// reads no tmux-assigned geometry and no rendered grids, so echo events recompute
    /// to the identical size. Returns `false` while the constants or the
    /// container size are still unknown, so the caller retries; hidden mirrors
    /// return `true` without sending (they push on becoming visible).
    @discardableResult
    func updateClientSize() -> Bool {
        guard !isTornDown else { return true }
        guard let connection else { return true }
        // Hidden mirrors write exactly ONCE — the initial claim. The first
        // per-window size on a connection drops every window WITHOUT one to
        // tmux's 80×24 default, so each mirrored window must claim its size
        // at attach even if its tab isn't selected yet. After that claim,
        // only the visible tab's mirror writes (hidden geometry callbacks
        // report collapsed sizes and must not resize the remote window
        // underneath the visible state).
        guard isVisibleForSizing || connection.lastWindowSizes[windowId] == nil else {
            return true
        }
        refreshGeometryConstants()
        #if DEBUG
        cmuxDebugLog(
            "remote.rects.push @\(windowId) container="
                + (containerSizePt.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")
                + " scale=\(containerScale ?? 0) geom=\(currentGeometry() != nil ? 1 : 0)"
                + " visible=\(isVisibleForSizing ? 1 : 0) panels=\(panelsByPaneId.count)"
        )
        #endif
        guard let containerSizePt, containerScale != nil,
              containerSizePt.width > 1, containerSizePt.height > 1,
              let cells = clientGrid(contentSize: containerSizePt)
        else { return false }
        connection.setWindowSize(
            windowId: windowId,
            columns: cells.columns,
            rows: cells.rows
        )
        return true
    }
}
