import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextInput
import CmuxNextLayout
import CmuxNextTabs
import QuartzCore

// Ghost presentation, the frame clock, and how a drag lands.
extension TabDragSession {
    // MARK: Ghost

    func present(_ drag: Drag) {
        let source = drag.source
        let tabSize = source.screenFrame.size
        let presentation: Presentation
        let rect: CGRect
        var scale: CGFloat = 1
        if let slot = drag.winner?.proposal.ghostFrame {
            presentation = .inline(slot)
            rect = TabDragGeometry.inlineRect(pointer: drag.point, grabOffset: source.grabOffset, tabSize: tabSize, slot: slot)
        } else {
            presentation = .card
            rect = TabDragGeometry.floatingRect(pointer: drag.point, grabOffset: source.grabOffset, tabSize: tabSize)
            if drag.winner != nil || drag.workspaceHighlight != nil { scale = DragTunables.ghostTargetScale.value }
        }
        let jump = presentation != drag.presentation
        drag.presentation = presentation
        let cardness: CGFloat = if case .inline = presentation { 0 } else { 1 }
        drag.motion.setTarget(rect, cardness: cardness, scale: scale, jump: jump)
        drag.ghost.render(drag.motion)
    }

    func wake(_ drag: Drag) {
        drag.link?.activate()
    }

    /// One ghost frame; false once the ghost settled.
    func tick(_ current: Drag, elapsed dt: Double) -> Bool { // perf-hot: 2ms drag-frame (every frame of a drag)
        guard current === drag || current === landing else { return false }
        var moving = current.motion.step(dt)
        if current === drag {
            let scrolled = autoscroll(current, dt: dt)
            // A pointer resting on a pane edge or a sidebar slot sends no events: hit-test again once it arms.
            let dwell = (current.winner?.provider as? LayoutTabDropTarget)?.dwellDeadline
                ?? (current.winner?.provider as? SidebarTabDropTarget)?.dwellDeadline
            let armed = dwell.map { CACurrentMediaTime() >= $0 } ?? false
            // Content moved under the pointer or a dwell armed: one hit test for the frame, whichever asked.
            if scrolled || armed { retarget(current.point, drag: current) }
            moving = moving || scrolled || dwell != nil
        }
        current.ghost.render(current.motion)
        guard !moving else { return true }
        if current === landing { finishLanding() }
        return false
    }

    /// Auto-scrolls the columns screen under the pointer, as the last hit test resolved it: a frame
    /// picks no window. Strips and the sidebar auto-scroll themselves while they hold a drag.
    func autoscroll(_ drag: Drag, dt: Double) -> Bool {
        guard let target = drag.autoscroll, let layout = drag.autoscrollLayout else { return false }
        return layout.stepTabDragAutoscroll(target, dt: dt)
    }

    /// Resolves the edge auto-scroll at `point` in `controller` (the window under it), for the frames
    /// until the next hit test.
    func resolveAutoscroll(_ drag: Drag, at point: CGPoint, in controller: WindowController?) {
        let layout = controller?.content(atScreen: point)?.layoutView
        let target = layout.flatMap { layout in
            layout.window.flatMap { layout.tabDragAutoscroll(locationInWindow: $0.convertPoint(fromScreen: point)) }
        }
        drag.autoscroll = target
        drag.autoscrollLayout = target == nil ? nil : layout
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

    /// Stops the drag's input: its tap intercept and the app-resign observer.
    func endInput(_ drag: Drag) {
        drag.input?.cancel()
        drag.input = nil
        resignObserver = nil
    }

    func tearOffFrame(_ drag: Drag, at point: CGPoint, size: CGSize) -> CGRect {
        let visible = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let windowSize = size == .zero ? CGSize(width: 1100, height: 720) : size
        return TabDragGeometry.tearOffFrame(pointer: point, grabOffset: drag.source.grabOffset, tabSize: drag.source.screenFrame.size,
                                            tabOffset: drag.source.tabOffset, windowSize: windowSize, visible: visible)
    }
}
