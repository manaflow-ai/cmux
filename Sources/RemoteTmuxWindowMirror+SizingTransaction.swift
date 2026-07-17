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
        guard isVisibleForSizing || containerSizePt == nil else {
            // Never bank a hidden reading — but never lose it either.
            // Geometry callbacks fire only on change, so a reading dropped
            // here would not be re-delivered, and a reveal whose cached
            // re-push happens to be degenerate would leave the claim
            // derived from a pre-hide width. Park it instead: the next
            // visible pass judges it against a real bound before anything
            // banks, and a fresh reveal reading replaces it outright.
            if pointSize.width > 1, pointSize.height > 1 {
                pendingContainerSizePt = pointSize
                pendingContainerScale = scale
            }
            return
        }
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
            // A reading BEYOND the bound is pathological — the mirror's
            // region can never exceed the window's content area, so an
            // oversized proposal means some ancestor adopted a content
            // ideal, and it carries no information about the true slot.
            // Clamping it would bank the bound itself, which overstates the
            // region by however much chrome sits between window and mirror —
            // the live fuzz measured the resulting plans running ~30-40pt
            // wide at rest. Drop it and keep the last good reading; only a
            // first-ever reading clamps, so the initial claim still exists.
            // The verdict is re-checked once, though: during an AppKit
            // window resize this callback can carry the CORRECT post-resize
            // slot size while the window still reports its transient old
            // frame — the reading is truth and the bound is noise, and no
            // further callback comes once the region has its final size.
            // Truth delivered during a torn window state must not be
            // discarded on the noise's verdict, so the dropped reading is
            // parked and re-judged once against the next settled bound.
            let oversized = pointSize.width > bound.width + 0.5
                || pointSize.height > bound.height + 0.5
            #if DEBUG
            if oversized {
                dumpProposalAncestors(proposedWidth: pointSize.width, boundWidth: bound.width)
            }
            #endif
            if containerSizePt != nil, oversized {
                #if DEBUG
                cmuxDebugLog(
                    "mirror.container.note @\(windowId) proposed=\(Int(pointSize.width))x\(Int(pointSize.height)) bound=\(Int(bound.width))x\(Int(bound.height)) -> drop"
                )
                #endif
                pendingOversizedReading = (size: pointSize, scale: scale)
                setNeedsSizingPass()
                return
            }
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
        // A reading banked here is newer than anything parked above; the
        // parked reading must not resurface at the next pass and overwrite it.
        pendingOversizedReading = nil
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
        // An injected source that answers nil no longer pins the channel: it
        // falls through to the live probe and pane scan, so a test can seed
        // an initial bound and then hand the mirror to a real window. In a
        // headless composition the fall-through still resolves to nil.
        // The probe view is planted in the mirror's own subtree, so its
        // window survives portal churn that can briefly leave every hosted
        // pane view detached or hidden mid-sync — the pane scan below can go
        // dark exactly when a bound is needed most.
        if let window = hostProbeView?.window, window.isVisible {
            let size = window.contentLayoutRect.size
            if size.width > 1, size.height > 1 { return (size, window) }
        }
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
    /// Pins every mirror pane's terminal grid to exactly its tmux-assigned
    /// cells. A grid derived from the view diverges from tmux whenever the
    /// plan and the assignment disagree — a starved sibling's chrome floor
    /// leaves a pane short (dropped cells), and any surplus leaves it long
    /// (rows tmux never repaints, wrap flags tmux set that never fire) —
    /// and the mirror's text then reads differently than the pane it
    /// mirrors. The grid follows tmux; the view clips or letterboxes the
    /// difference: the same answer tmux gives a client whose size
    /// disagrees. Surface pixels only — the claim keeps deriving from the
    /// measured container, so nothing here can feed back.
    func applyAssignedGrids() {
        let leaves = renderedLayout.leavesByPaneID
        let baseLeaves = layout.leavesByPaneID
        // A stale re-pin during a WINDOW live-resize (or an interactive
        // geometry drag) would hold the surface at the pre-resize assignment
        // and paint past the shrinking pane — the same suppression the view
        // path applies at GhosttyTerminalView. The divider-drag early return
        // at the top of performSizingPassNow does NOT cover a window resize,
        // so gate the stale re-pin here. The fresh setAssignedGrid below is
        // left alone: it applies tmux's own assignment, never a stale one.
        let hostingWindow = visibleHostingContext()?.window
        let suppressPin = hostingWindow?.inLiveResize == true
            || TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: hostingWindow)
        var panesToRepaint: [Int] = []
        for (paneId, panel) in panelsByPaneId {
            // Under zoom the visible tree is the single zoomed leaf, but the
            // hidden BASE panes are still live and still receiving output —
            // pin each to its base grid so it never renders on a stale one.
            // The zoomed pane pins its full visible grid (visible wins). Only
            // a pane in NEITHER tree is genuinely removed; clear that pin.
            guard let node = leaves[paneId] ?? baseLeaves[paneId],
                  node.width > 0, node.height > 0 else {
                panel.surface.clearAssignedGrid()
                continue
            }
            let grewPin = panel.surface.setAssignedGrid(columns: node.width, rows: node.height)
            var laggedShort = false
            if !grewPin, !suppressPin,
               let rendered = lastRenderedGrids[paneId],
               rendered.cols != node.width || rendered.rows != node.height {
                // The pin value already equals the assignment, but the surface
                // rendered a DIFFERENT grid: tmux grew the pane after the pin
                // last applied (against stale cell metrics between our claim and
                // settle) and an unchanged setAssignedGrid is a no-op, or the
                // surface over-rendered past the assignment. Re-apply against the
                // current metrics — reapplyAssignedGrid clamps both directions.
                panel.surface.reapplyAssignedGrid()
                laggedShort = rendered.cols < node.width || rendered.rows < node.height
            }
            // A grid that grew after tmux streamed those rows leaves the
            // late-granted cells blank: the surface clipped that content while it
            // was short, and tmux repaints only on change. tmux's own grid still
            // HAS those rows — only the mirror lost them — so the repair is to read
            // tmux's screen back into this pane, never to move the CLIENT size. The
            // old shrink→restore kick did move it, which made tmux re-round an odd
            // split, which grew a pane again and re-fired the kick: an unbounded
            // loop (23k kicks in one fuzz iteration). Rationing the kick by a
            // per-pane high-water bounded the loop but silently dropped genuine
            // grows (a grow back to a size already refilled at this claim never
            // repainted, so its cells stayed blank). A capture-pane read perturbs
            // nothing, so every genuine grow can repaint exactly once with no
            // budget, no high-water, and no loop.
            if grewPin || laggedShort {
                panesToRepaint.append(paneId)
            }
        }
        // Sorted so the command order is deterministic under churn.
        for paneId in panesToRepaint.sorted() {
            connection?.repaintPaneVisibleScreen(paneId: paneId)
        }
    }

    /// The first renderable pane whose last sampled grid is behind the cells
    /// tmux assigned it. This is the residual the input-only settle proof
    /// cannot see: `renderedLayout` is part of the sizing inputs, but a pin
    /// that applied against stale cell metrics can leave the surface one
    /// row/column short of an assignment that grew between our claim and
    /// settle, so the pane renders short and wraps while inputs read
    /// unchanged. Panes tmux itself squeezed to a one-cell axis carry no
    /// renderable grid (the render oracle skips them the same way), so they
    /// never count as a lag.
    func gridParityMismatch() -> String? {
        for (paneId, node) in renderedLayout.leavesByPaneID {
            guard node.width > 1, node.height > 1 else { continue }
            // Read the surface's LIVE grid first: the ledger goes stale
            // because a same-size re-apply returns early before reporting
            // (TerminalSurface+Sizing), so a pane that quietly drifted off
            // its assignment would read parity-clean from the cache alone.
            // rawSizingSample() is @MainActor and this runs on main.
            let liveGrid = panelsByPaneId[paneId]?.surface.rawSizingSample()
                .map { (cols: $0.columns, rows: $0.rows) }
            guard let rendered = liveGrid ?? lastRenderedGrids[paneId] else { continue }
            // Either direction is a mismatch: a short pane wraps, and an
            // over-rendered pane holds rows tmux never repaints. The recovery
            // pass re-applies the pin, which clamps both ways.
            if rendered.cols != node.width || rendered.rows != node.height {
                return "pane=%\(paneId) assigned=\(node.width)x\(node.height)"
                    + " rendered=\(rendered.cols)x\(rendered.rows)"
            }
        }
        return nil
    }

    func performSizingPassNow() {
        sizingPassScheduled = false
        guard !isTornDown else { return }
        #if DEBUG
        RemoteTmuxSizingDiagnostics.sizingPassCount += 1
        #endif
        // While the user is dragging a divider, hold the pass. Imposing now
        // would move the divider out from under the pointer and mark the
        // dragged split as imposed again, so its resize-pane at drag end
        // would be skipped (see the render-ownership section of the design
        // doc). The drag-end delegate callback always schedules a fresh pass
        // — and this return sits BEFORE the intent reset below, so a held
        // recovery pass keeps its `.constraintRecovery` intent for drag end.
        if bonsplitController.isDividerDragActive { return }
        let intent = pendingSizingPassIntent
        let hostingContext = visibleHostingContext()
        let visibleHostingBound = hostingContext?.contentSize
        // A reading the oversized guard rejected gets exactly one
        // re-judgment, against a SETTLED bound: a mid-resize callback can
        // carry the true post-resize slot while the window's transient frame
        // undersells it, and no later callback re-delivers that truth. If
        // the reading fits the settled bound it was truth all along — bank
        // it verbatim. If it still exceeds the bound it is a content ideal
        // and stays discarded; it is never clamped (see noteContainerSize).
        // A pass with NO bound (portal darkness — every hosted view briefly
        // detached or hidden mid-churn) judges nothing: consuming the parked
        // reading there lost the one re-judgment, and the reveal path never
        // re-delivers it — the reading stays parked for the next bounded
        // pass instead.
        // Consume the parked reading only against a SETTLED bound. While the
        // hosting window is in a live resize it still reports its transient
        // (old, smaller) frame, so a valid post-resize reading that legitimately
        // exceeds that frame would be judged against noise and discarded for
        // good — the window never re-delivers it. Leave it parked; live-resize
        // end fires a fresh geometry callback whose settled pass consumes it.
        // A nil window (an injected bound, or the no-host fallback) is treated
        // as settled: there is no live resize to wait on.
        if let parked = pendingOversizedReading, let bound = visibleHostingBound,
           hostingContext?.window?.inLiveResize != true {
            pendingOversizedReading = nil
            if parked.size.width <= bound.width + 0.5,
               parked.size.height <= bound.height + 0.5 {
                containerSizePt = parked.size
                containerScale = parked.scale
            }
        }
        // Adopt a detached callback, or re-clamp a prior value, as soon as
        // any pane is visibly hosted. This pass is also the recovery path
        // when attachment itself does not emit another geometry callback.
        if let bound = visibleHostingBound {
            if let size = pendingContainerSizePt {
                // Mirror the oversized-reading reject rule (see the parked
                // consumer above): a parked reading BEYOND the settled bound
                // is a content ideal, not the slot. Clamping and banking it
                // would overwrite a correct container with the bound itself
                // (inflated by the chrome between window and mirror). Drop it
                // and keep the last good reading. A reading that fits banks
                // verbatim — the old min() clamp was a no-op there anyway.
                if size.width > bound.width + 0.5 || size.height > bound.height + 0.5 {
                    pendingContainerSizePt = nil
                    pendingContainerScale = nil
                } else {
                    containerSizePt = size
                    containerScale = pendingContainerScale
                    pendingContainerSizePt = nil
                    pendingContainerScale = nil
                }
            } else if var size = containerSizePt,
                      size.width > bound.width + 0.5 || size.height > bound.height + 0.5 {
                size.width = min(size.width, bound.width)
                size.height = min(size.height, bound.height)
                containerSizePt = size
            }
        }
        let inputs = currentSizingInputs()
        if inputs == lastCompletedSizingInputs {
            // Settled by the input proof — but that proof says nothing about
            // the OUTPUT. Verify two turns out that the views actually hold
            // the plan, so an apply that terminated off-target cannot hide
            // behind unchanged inputs (see rearmIfOutputMissedPlan).
            scheduleOutputParityCheck()
            return
        }
        guard updateClientSize() else { return }
        // A visible transaction is not complete until its live host exists:
        // the claim may be sent while detached, but divider imposition and the
        // portal catch-up are the other half of the same transaction.
        guard !inputs.visible || hostingContext != nil else { return }
        pendingSizingPassIntent = .inputChange
        lastCompletedSizingInputs = inputs
        // A new fixed point gets a fresh re-arm budget; a recovery pass for
        // the SAME inputs (lastCompletedSizingInputs was nil'd) keeps
        // spending the old one, or the re-arm edge would loop unbounded.
        if outputParityRearmInputs != inputs {
            outputParityRearmInputs = inputs
            outputParityRearmsSpent = 0
        }
        if inputs.visible {
            let frameBefore = renderFrameSize
            updateRenderFrameSize()
            imposeDividerPlan(retryImposedExtents: intent == .constraintRecovery)
            applyAssignedGrids()
            // A changed render frame applies on the NEXT SwiftUI commit —
            // after the impositions above — and AppKit's rescale then moves
            // every divider off the extents just applied, with nothing left
            // to put them back (inputs unchanged, container changed). Restate
            // the plan once, two turns out, after the frame has landed. The
            // follow-up pass sees the same render frame, so it cannot
            // schedule another: one bounded echo, not a loop.
            if renderFrameSize != frameBefore {
                DispatchQueue.main.async {
                    DispatchQueue.main.async { [weak self] in
                        self?.setNeedsSizingPassIgnoringInputs()
                    }
                }
            }
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
            // The other half of the transaction's contract: the apply above
            // lands on later turns (bonsplit's deferred apply, AppKit's
            // rescale), and it may terminate off-target — bonsplit can park
            // a divider at a minimum, a retry budget can expire against
            // mid-commit bounds. Verify the outcome once the geometry has
            // had two turns to land, and re-arm (bounded) if it missed.
            scheduleOutputParityCheck()
        }
    }

    /// Schedules `rearmIfOutputMissedPlan()` two runloop turns out —
    /// after bonsplit's deferred apply and AppKit's layout pass have landed,
    /// and OFF any layout callback, like the render-frame restate above.
    /// Coalesced: a burst of settled triggers buys one check.
    private func scheduleOutputParityCheck() {
        guard !outputParityCheckScheduled, !isTornDown else { return }
        outputParityCheckScheduled = true
        DispatchQueue.main.async {
            DispatchQueue.main.async { [weak self] in
                self?.outputParityCheckScheduled = false
                self?.rearmIfOutputMissedPlan()
            }
        }
    }

    /// The output side of the convergence proof. The transaction's settled
    /// check compares INPUTS; this compares the OUTCOME — the outer sizes
    /// the last imposition granted against the hosted views' actual frames
    /// (the settle payload's own comparison, tolerance and all). An apply
    /// may never terminate off-target without a re-arm edge: when the views
    /// miss the plan at an input fixed point, request one recovery pass,
    /// capped per fixed point so an extent bonsplit genuinely cannot apply
    /// (a hard minimum) stops after a bounded correction instead of looping.
    func rearmIfOutputMissedPlan() {
        guard !isTornDown, !sizingPassScheduled, isEffectivelyVisibleForSizing,
              !bonsplitController.isDividerDragActive,
              // A sent divider resize makes the plan KNOWN stale until the
              // reply assigns the sent span: the views hold the user's
              // dragged position and re-imposing the pre-drag plan is the
              // bounce this re-arm must not cause. The hold is keyed and
              // release-guaranteed by protocol edges (see
              // dividerResizeInFlight); its no-op verdict re-arms this
              // path itself.
              dividerResizeInFlight == nil,
              let completed = lastCompletedSizingInputs,
              completed == currentSizingInputs()
        else { return }
        guard outputParityRearmsSpent < 3 else { return }
        // Re-arm on EITHER a hosted-frame miss (the plan's points never
        // reached the views) OR a grid-lag miss (the pin never followed an
        // assignment that grew); the recovery pass re-imposes the plan and
        // re-applies the pin, and the cap bounds a miss that genuinely cannot
        // converge.
        guard let mismatch = outputParityMismatch() ?? gridParityMismatch() else { return }
        outputParityRearmsSpent += 1
        #if DEBUG
        RemoteTmuxSizingDiagnostics.parityRearmCount += 1
        cmuxDebugLog(
            "remote.parity.rearm @\(windowId) \(mismatch) attempt=\(outputParityRearmsSpent)/3"
        )
        #endif
        setNeedsSizingPassIgnoringInputs()
    }

    /// First pane whose hosted view sits outside the settle tolerance of its
    /// planned outer size, or nil when every hosted pane holds the plan.
    /// Planned outers carry the per-pane tab bar; the hosted view is the
    /// content below it — the same adjustment the settle payload makes.
    private func outputParityMismatch() -> String? {
        guard !lastPlannedOuterSizes.isEmpty,
              let metrics = nativeLayoutMetrics() else { return nil }
        for (paneId, planned) in lastPlannedOuterSizes {
            guard let view = panelsByPaneId[paneId]?.hostedView,
                  view.window != nil else { continue }
            let content = CGSize(
                width: planned.width,
                height: max(0, planned.height - metrics.tabBarHeight)
            )
            let actual = view.frame.size
            if abs(content.width - actual.width) > 1.5
                || abs(content.height - actual.height) > 1.5 {
                return "pane=%\(paneId)"
                    + " plan=\(Int(content.width))x\(Int(content.height))"
                    + " view=\(Int(actual.width))x\(Int(actual.height))"
            }
        }
        return nil
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

    /// The point size the split tree renders at: the tmux grid it holds plus
    /// its chrome — not the whole region. The region is rarely an exact
    /// multiple of the cell grid; the sub-cell remainder (up to one cell per
    /// axis) must stay OUTSIDE the tree as trailing margin, because inside it
    /// would land in some pane along a split axis and floor to an extra row
    /// or column there. Same answer tmux gives a too-big client: a border.
    /// Inputs are the region, the metrics, and tmux's tree — nothing measured
    /// from rendering — so this cannot feed back.
    func updateRenderFrameSize() {
        guard let container = containerSizePt,
              let metrics = nativeLayoutMetrics(),
              renderedLayout.width > 0, renderedLayout.height > 0 else {
            if renderFrameSize != nil { renderFrameSize = nil }
            return
        }
        let exact = metrics.exactFitSize(
            columns: renderedLayout.width,
            rows: renderedLayout.height,
            layout: renderedLayout
        )
        let clamped = CGSize(
            width: min(exact.width, container.width),
            height: min(exact.height, container.height)
        )
        if renderFrameSize != clamped {
            renderFrameSize = clamped
            #if DEBUG
            cmuxDebugLog(
                "mirror.renderFrame @\(windowId) grid=\(renderedLayout.width)x\(renderedLayout.height)"
                    + " exact=\(Int(exact.width))x\(Int(exact.height))"
                    + " region=\(Int(container.width))x\(Int(container.height))"
                    + " -> \(Int(clamped.width))x\(Int(clamped.height))"
            )
            #endif
        }
    }

    #if DEBUG
    /// The mirror's real ancestor chain, host probe to window, one entry per
    /// view — the walk shared by the growth-spiral tripwire log below and
    /// the `remote.tmux.root_frames` verb, so the two report the same chain.
    func hostProbeAncestorChain(
        maxDepth: Int = 16
    ) -> [(className: String, width: CGFloat, height: CGFloat)] {
        var chain: [(className: String, width: CGFloat, height: CGFloat)] = []
        var current: NSView? = hostProbeView
        while let view = current, chain.count < maxDepth {
            chain.append((
                className: NSStringFromClass(type(of: view)),
                width: view.frame.width,
                height: view.frame.height
            ))
            current = view.superview
        }
        return chain
    }

    /// At container-suspect time, walk from the host probe to the window
    /// logging each ancestor's class and width, then name the inflated
    /// SUBTREE: at each ancestor wider than the bound, list its direct
    /// children — the child that carries the width at the level where the
    /// parent is still sane is the leak. Scroll documents are exempt
    /// (clipped). Once per window: this fires per dropped reading, and one
    /// chain identifies the leak — a drop storm repeating it drowns the log.
    func dumpProposalAncestors(proposedWidth: CGFloat, boundWidth: CGFloat?) {
        guard !dumpedAncestorChains else { return }
        dumpedAncestorChains = true
        guard let probe = hostProbeView else {
            cmuxDebugLog("mirror.container.ancestors @\(windowId) NO-PROBE proposed=\(Int(proposedWidth))")
            return
        }
        let chain = hostProbeAncestorChain(maxDepth: 14).map {
            "\(String($0.className.prefix(48)))=\(Int($0.width))"
        }
        cmuxDebugLog(
            "mirror.container.ancestors @\(windowId) proposed=\(Int(proposedWidth)) bound=\(boundWidth.map { String(Int($0)) } ?? "nil") \(chain.joined(separator: " < "))"
        )
        guard let bound = boundWidth else { return }
        var current: NSView? = probe.superview
        var depth = 0
        while let view = current, depth < 14 {
            if view.frame.width > bound + 0.5, !(view.superview is NSClipView) {
                let kids = view.subviews.prefix(8).map {
                    "\(String(NSStringFromClass(type(of: $0)).suffix(28)))=\(Int($0.frame.width))"
                }.joined(separator: " ")
                cmuxDebugLog(
                    "mirror.container.kids @\(windowId) level=\(depth) \(String(NSStringFromClass(type(of: view)).suffix(28)))=\(Int(view.frame.width)) kids[\(kids)]"
                )
            }
            current = view.superview
            depth += 1
        }
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
            // Chrome parity: the same shared points→cells model the tests
            // use, applied to the extent the plan granted this pane. If the
            // plan's expectation ALSO disagrees with what the surface
            // sampled, the chrome model and the painted chrome have drifted
            // — the drift class that otherwise rots silently.
            if let planned = lastPlannedOuterSizes[paneId],
               let metrics = nativeLayoutMetrics(),
               let geometry = currentGeometry() {
                // Planned outers carry no native title-row points (tmux's
                // title rows live in the tree's coordinates and cost the
                // native render nothing), so the probe subtracts none.
                let expected = RemoteTmuxNativeLayoutMetrics.renderedCells(
                    outer: planned,
                    tabBarHeight: metrics.tabBarHeight,
                    scale: geometry.scale,
                    surfacePadPx: (width: geometry.surfacePadWidthPx, height: geometry.surfacePadHeightPx),
                    cellPx: (width: geometry.cellWidthPx, height: geometry.cellHeightPx)
                )
                if sample.columns != expected.columns || sample.rows != expected.rows {
                    cmuxDebugLog(
                        "remote.parity.mismatch @\(windowId) pane=%\(paneId)"
                            + " sampled=\(sample.columns)x\(sample.rows)"
                            + " expectedFromPlan=\(expected.columns)x\(expected.rows)"
                            + " planned=\(Int(planned.width))x\(Int(planned.height))pt"
                    )
                }
            }
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
