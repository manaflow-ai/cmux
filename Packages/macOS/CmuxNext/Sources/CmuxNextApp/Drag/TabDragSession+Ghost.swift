import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextSignposts
import CmuxNextTabs
import QuartzCore

// Ghost presentation, the frame clock, and how a drag lands.
extension TabDragSession {
    // MARK: Ghost

    /// Shows `drag`'s ghost at its target. `order` is this pointer event's window order (render server:
    /// it decides whether the source window's overlay holds the ghost).
    func present(_ drag: Drag, order: [TabDragWindowPick.Candidate]) {
        let source = drag.source
        let tabSize = source.screenFrame.size
        // Drawn at the resampled pointer; the target (`drag.winner`) was hit-tested at the real one.
        let pointer = drag.shownPoint ?? drag.point
        let presentation: Presentation
        let rect: CGRect
        var scale: CGFloat = 1
        if let slot = drag.winner?.proposal.ghostFrame {
            presentation = .inline(slot)
            rect = TabDragGeometry.inlineRect(pointer: pointer, grabOffset: source.grabOffset, tabSize: tabSize, slot: slot)
        } else {
            presentation = .card
            rect = TabDragGeometry.floatingRect(pointer: pointer, grabOffset: source.grabOffset, tabSize: tabSize)
            if drag.winner != nil || drag.workspaceHighlight != nil { scale = DragTunables.ghostTargetScale.value }
        }
        let jump = presentation != drag.presentation
        drag.presentation = presentation
        let cardness: CGFloat = if case .inline = presentation { 0 } else { 1 }
        drag.motion.setTarget(rect, cardness: cardness, scale: scale, jump: jump)
        guard drag.ghost.rendersOnServer else { return drag.ghost.render(drag.motion) }
        drag.ghost.present(drag.motion, token: jump ? .track : .appear, holds: sourceHolds(drag, order: order))
    }

    /// The ghost changed without a new target (its preview arrived): the CPU path steps it from
    /// the next frame, the render server springs it now. A drag that ended and landed shows nothing.
    func redraw(_ drag: Drag) {
        guard drag === self.drag || drag === landing else { return }
        guard drag.ghost.rendersOnServer else { return wake(drag) }
        drag.ghost.present(drag.motion, token: .appear, holds: sourceHolds(drag, order: windowOrder(for: drag)))
    }

    /// Whether the source window shows a screen rect in front of every other window, while the
    /// pointer is over it (Chrome's attached drag); nil elsewhere.
    func sourceHolds(_ drag: Drag, order: [TabDragWindowPick.Candidate]) -> ((CGRect) -> Bool)? {
        Self.holds(drag.source.window?.state.id, at: drag.point, in: order)
    }

    /// Whether content window `id` shows a screen rect in front of every other window, while `point` is over
    /// it; nil elsewhere (or with no `id`). Tab and workspace ghosts and the link pill (``LinkDragSession``)
    /// show in that window's overlay only where this holds.
    static func holds(_ id: String?, at point: CGPoint, in order: [TabDragWindowPick.Candidate]) -> ((CGRect) -> Bool)? {
        guard let id, TabDragWindowPick.frontmost(at: point, in: order) == id else { return nil }
        return { TabDragWindowPick.isFrontmost(id, over: $0, in: order) }
    }

    func wake(_ drag: Drag) {
        drag.link?.activate()
    }

    /// Wakes the frame clock after a pointer event over `controller`. The CPU path steps the ghost
    /// on it; on the render server it runs only while the pointer auto-scrolls a columns screen or a
    /// dwell is armed, as Chrome's tab drag runs its scroll timer only in the edge zone
    /// (chrome/browser/ui/views/tabs/tab_drag_controller.cc `StartScrollingTimer`).
    func wake(_ drag: Drag, over controller: WindowController?) {
        guard drag.ghost.rendersOnServer else { return wake(drag) }
        if dwellDeadline(drag) != nil || autoscrolls(drag, in: controller) { wake(drag) }
    }

    /// When a pointer resting on a pane edge or a sidebar slot arms its drop.
    func dwellDeadline(_ drag: Drag) -> CFTimeInterval? {
        (drag.winner?.provider as? LayoutTabDropTarget)?.dwellDeadline ?? (drag.winner?.provider as? SidebarTabDropTarget)?.dwellDeadline
    }

    /// Whether the pointer sits in a columns screen's auto-scroll band of `controller`.
    func autoscrolls(_ drag: Drag, in controller: WindowController?) -> Bool {
        guard let layout = controller?.content(atScreen: drag.point)?.layoutView, let window = layout.window else { return false }
        return layout.tabDragAutoscrolls(locationInWindow: window.convertPoint(fromScreen: drag.point))
    }

    /// One ghost frame; false once the ghost settled. On the render server nothing steps the
    /// ghost: the frame only auto-scrolls and re-tests a dwell. The frame is one `motion.drag_frame`
    /// thread slice holding the tick's dt in us: the ghost's step, the autoscroll, the drop-target hit
    /// test and the render (Chrome's per-frame slice, `ProxyMain::BeginMainFrame` in cc/trees/proxy_main.cc).
    func tick(_ current: Drag, elapsed dt: Double) -> Bool { // perf-hot: 2ms drag-frame (every frame of a drag)
        guard current === drag || current === landing else { return false }
        let frame = motionSignposter.begin(.motionDragFrame, "", arg0: Self.dragFrameMicros(seconds: dt))
        defer { motionSignposter.end(.motionDragFrame, frame) }
        let onServer = current.ghost.rendersOnServer
        var moving = onServer ? false : current.motion.step(dt)
        if current === drag, autoscroll(current, dt: dt) {
            update(current.point, shown: current.shownPoint)
            moving = true
        }
        // A pointer resting on a pane edge or a sidebar slot sends no events: hit-test again once it arms.
        if current === drag, let deadline = dwellDeadline(current) {
            if CACurrentMediaTime() >= deadline { update(current.point, shown: current.shownPoint) }
            moving = true
        }
        if !onServer { current.ghost.render(current.motion) }
        guard !moving else { return true }
        if current === landing, !onServer { finishLanding() }
        return false
    }

    /// `seconds` in whole microseconds, 0 for a negative or NaN time, saturated at `UInt32.max`.
    static func dragFrameMicros(seconds: Double) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(min((seconds * 1_000_000).rounded(), Double(UInt32.max)))
    }

    /// Auto-scrolls the columns screen under the pointer. Strips and the
    /// sidebar auto-scroll themselves while they hold a drag.
    func autoscroll(_ drag: Drag, dt: Double) -> Bool {
        guard let controller = window(at: drag.point), let layout = controller.content(atScreen: drag.point)?.layoutView, let window = layout.window else {
            return false
        }
        return layout.autoscrollTabDrag(locationInWindow: window.convertPoint(fromScreen: drag.point), dt: dt)
    }

    // MARK: Finish

    /// Ends the drag: commits the current outcome, or cancels with a spring
    /// back. Every path ends the lifecycle.
    func finish(commit: Bool) {
        guard let drag else { return }
        self.drag = nil
        endInput(drag)
        if case .workspaces = drag.source.item { return finishWorkspaces(drag, commit: commit) }
        let outcome = commit ? drag.outcome : .cancel
        if commit { noteCommit(drag) }
        focusDragEnded(drag, outcome: outcome)
        let winner = drag.winner
        for provider in drag.touched.values where provider !== winner?.provider || outcome == .cancel {
            provider.dropEnded(committed: nil)
        }
        // A strip slot's outline lives in a layout that may not have answered.
        drag.outlinedLayout?.dropExited()
        drag.outlinedLayout = nil
        switch outcome {
        case .cancel:
            drag.lifecycle.cancel()
            land(drag, at: drag.source.screenFrame, cardness: 0, opacity: 1, scale: 1)
        case .moveWindow(let point):
            drag.lifecycle.cancel()
            if let window = drag.source.window?.window {
                window.setFrame(tearOffFrame(drag, at: point, size: window.frame.size), display: true)
            }
            land(drag, at: drag.source.screenFrame, cardness: 0, opacity: 0, scale: 1)
        case .moveWorkspaceToNewWindow, .moveWorkspace:
            // The tabs stay in their workspace; the workspace itself moves.
            drag.lifecycle.cancel()
            moveSourceWorkspace(outcome, drag: drag)
            land(drag, at: drag.source.screenFrame, cardness: 0, opacity: 0, scale: 1)
        default:
            winner?.provider.dropEnded(committed: winner?.proposal)
            guard let transaction = drag.lifecycle.beginCommit() else { return land(drag, at: drag.motion.targetRect, cardness: 0, opacity: 0, scale: 1) }
            execute(outcome, drag: drag, transaction: transaction)
            if let slot = winner?.proposal.ghostFrame {
                land(drag, at: slot, cardness: 0, opacity: 1, scale: 1)
            } else {
                let target = winner?.proposal.highlightFrame ?? drag.motion.targetRect
                let tab = drag.motion.targetRect
                land(drag, at: CGRect(x: target.midX - tab.width / 2, y: target.midY - tab.height / 2, width: tab.width, height: tab.height),
                     cardness: 1, opacity: 0, scale: DragTunables.ghostLandScale.value)
            }
        }
    }

    /// A drop where nothing answered inside a window is a resolver defect and says so instead of springing back
    /// silently (tab-dnd); a refused zone springs back without a word (Lawrence 2026-10-05). A drop into a workspace
    /// shown beside the focused one (`sidebar.multiView`) focuses it first, unless Option files the tabs away.
    func noteCommit(_ drag: Drag) {
        guard case .none = drag.resolution.preview else { return drag.filesAway ? () : drag.winner?.window?.focusDropTarget(drag.outcome, atScreen: drag.point) ?? () }
        services.registry.refuse(drag.noTargetReason ?? TabDropStrings.noTarget)
    }

    /// Animates the ghost to its landing and closes it when it settles.
    func land(_ drag: Drag, at rect: CGRect, cardness: CGFloat, opacity: CGFloat, scale: CGFloat) {
        finishLanding()
        // The release settles with a slightly under-damped spring.
        drag.motion.rectSpring = Motion.tabs.spring(.settle)
        drag.motion.setTarget(rect, cardness: cardness, opacity: opacity, scale: scale, jump: true,
                              velocity: drag.releaseVelocity(at: CACurrentMediaTime()))
        landing = drag
        if drag.ghost.rendersOnServer {
            // The flight is one render-server spring; its landing closes the ghost (`onRest`).
            drag.link?.deactivate()
            drag.ghost.present(drag.motion, token: .settle, holds: nil, landing: true)
            return
        }
        if drag.motion.reduceMotion {
            finishLanding()
            return
        }
        drag.ghost.render(drag.motion)
        wake(drag)
    }

    func finishLanding() {
        guard let landing else { return }
        self.landing = nil
        end(landing)
    }

    func end(_ drag: Drag) {
        endInput(drag)
        drag.link?.deactivate()
        drag.link = nil
        drag.ghost.close()
    }

    /// Stops the drag's input: its tap intercept, its pending moves and the app-resign observer.
    func endInput(_ drag: Drag) {
        drag.input?.cancel()
        drag.input = nil
        drag.moves?.cancel()
        drag.moves = nil
        resignObserver?.cancel()
        resignObserver = nil
    }

    func tearOffFrame(_ drag: Drag, at point: CGPoint, size: CGSize) -> CGRect {
        let visible = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let windowSize = size == .zero ? CGSize(width: 1100, height: 720) : size
        return TabDragGeometry.tearOffFrame(pointer: point, grabOffset: drag.source.grabOffset, tabSize: drag.source.screenFrame.size,
                                            tabOffset: drag.source.tabOffset, windowSize: windowSize, visible: visible)
    }
}
