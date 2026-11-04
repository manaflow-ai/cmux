public import AppKit
import CmuxNextDesign

/// The floating chat (cx-b9qi): once a started chat stays in the panel, it
/// resizes, drags by its top edge or with ⌘ anywhere, and keeps the frame it
/// was left at on each screen.
extension QuickComposerPanel {
    public func holdChat(_ holds: Bool) {
        guard holds != holdsChat else { return }
        holdsChat = holds
        grip.isHidden = !holds
        if holds {
            // A material rebuild (Reduce Transparency) re-adds the glass on top; the grip goes back over it.
            grip.superview?.addSubview(grip, positioned: .above, relativeTo: nil)
            styleMask.insert(.resizable)
            minSize = FloatingChatFrames.minimumSize
            guard let screen = screen ?? Self.screenUnderPointer() else { return }
            let saved = frames.frame(onDisplay: FloatingChatFrames.display(screen))
            // Hidden (a tab moved here), it opens where the composer would.
            let near = isVisible ? frame : Self.placement(size: frame.size, in: screen.visibleFrame)
            animateFrame(to: FloatingChatFrames.placement(saved: saved, near: near, in: screen.visibleFrame))
        } else {
            styleMask.remove(.resizable)
            level = .floating
            let size = frameRect(forContentRect: CGRect(origin: .zero, size: Self.size)).size
            setFrameNow(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height))
        }
    }

    /// Floats over other apps' windows, or sits among them like a document window.
    public func setOnTop(_ onTop: Bool) {
        level = onTop ? .floating : .normal
    }

    /// Folds to the compact bar, its top edge where it was, or opens back to
    /// the height it had, kept on its screen.
    public func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        let top = frame.maxY
        var target: CGRect
        if collapsed {
            expandedHeight = frame.height
            minSize = CGSize(width: FloatingChatFrames.minimumSize.width, height: FloatingChatFrames.barHeight)
            maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: FloatingChatFrames.barHeight)
            target = CGRect(x: frame.minX, y: top - FloatingChatFrames.barHeight, width: frame.width, height: FloatingChatFrames.barHeight)
        } else {
            minSize = FloatingChatFrames.minimumSize
            maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            let height = expandedHeight ?? FloatingChatFrames.defaultSize.height
            target = CGRect(x: frame.minX, y: top - height, width: frame.width, height: height)
            if let visible = screen?.visibleFrame { target = FloatingChatFrames.placement(saved: target, near: target, in: visible) }
        }
        animateFrame(to: target)
    }

    /// Moves and resizes to `target` on the overlays gate (never `setFrame(_:display:animate:)`,
    /// whose animation blocks the main thread); hidden (the chat moved to a tab), at once: a late
    /// animation would size the next composer. The page follows the panel's size on every frame.
    private func animateFrame(to target: CGRect) {
        guard isVisible else { return setFrameNow(target) }
        Motion.overlays.animateTimed(.panel, in: contentView) { animator().setFrame(target, display: true) }
    }

    /// Sets `target` at once and takes over a frame animation in flight: a zero-length animator
    /// group replaces it, so it never lands later.
    private func setFrameNow(_ target: CGRect) {
        let display = isVisible
        Motion.withoutAnimation { animator().setFrame(target, display: display) }
    }

    public func windowDidMove(_ notification: Notification) { saveFrame() }

    public func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        // The compact bar's height is not the floating chat's.
        guard holdsChat, !isCollapsed, let screen else { return }
        frames.save(frame, onDisplay: FloatingChatFrames.display(screen))
    }
}
