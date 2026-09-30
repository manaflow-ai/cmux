import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
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
            if drag.winner != nil || drag.workspaceHighlight != nil { scale = 0.9 }
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
    func tick(_ current: Drag, elapsed dt: Double) -> Bool {
        guard current === drag || current === landing else { return false }
        var moving = current.motion.step(dt)
        if current === drag, autoscroll(current, dt: dt) {
            update(current.point)
            moving = true
        }
        current.ghost.render(current.motion)
        guard !moving else { return true }
        if current === landing { finishLanding() }
        return false
    }

    /// Auto-scrolls the columns screen under the pointer. Strips and the
    /// sidebar auto-scroll themselves while they hold a drag.
    func autoscroll(_ drag: Drag, dt: Double) -> Bool {
        guard let controller = window(at: drag.point), let layout = controller.content?.layoutView, let window = layout.window else {
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
        removeMonitors(drag)
        if case .workspaces = drag.source.item { return finishWorkspaces(drag, commit: commit) }
        let outcome = commit ? drag.outcome : .cancel
        focusDragEnded(drag, outcome: outcome)
        let winner = drag.winner
        for provider in drag.touched.values where provider !== winner?.provider || outcome == .cancel {
            provider.dropEnded(committed: nil)
        }
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
                     cardness: 1, opacity: 0, scale: 0.7)
            }
        }
    }

    /// Animates the ghost to its landing and closes it when it settles.
    func land(_ drag: Drag, at rect: CGRect, cardness: CGFloat, opacity: CGFloat, scale: CGFloat) {
        finishLanding()
        // The release settles with a slightly under-damped spring.
        drag.motion.rectSpring = Motion.spring(.settle)
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
        removeMonitors(drag)
        drag.link?.deactivate()
        drag.link = nil
        drag.ghost.close()
    }

    func removeMonitors(_ drag: Drag) {
        if let monitor = drag.monitor { NSEvent.removeMonitor(monitor) }
        drag.monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    func tearOffFrame(_ drag: Drag, at point: CGPoint, size: CGSize) -> CGRect {
        let visible = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let windowSize = size == .zero ? CGSize(width: 1100, height: 720) : size
        return TabDragGeometry.tearOffFrame(pointer: point, grabOffset: drag.source.grabOffset, tabSize: drag.source.screenFrame.size,
                                            tabOffset: drag.source.tabOffset, windowSize: windowSize, visible: visible)
    }
}
