import AppKit

/// The floating chat (cx-b9qi): once a started chat stays in the panel, it
/// resizes, drags by its top edge or with ⌘ anywhere, and keeps the frame it
/// was left at on each screen.
extension QuickComposerPanel {
    func holdChat(_ holds: Bool) {
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
            setFrame(FloatingChatFrames.placement(saved: saved, near: frame, in: screen.visibleFrame), display: true, animate: isVisible)
        } else {
            styleMask.remove(.resizable)
            setContentSize(Self.size)
        }
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard holdsChat, let screen else { return }
        frames.save(frame, onDisplay: FloatingChatFrames.display(screen))
    }
}

/// The floating chat's top edge: a drag there moves the panel. The page
/// under it would take the press, and a web view never moves its window.
final class FloatingChatGrip: NSView {
    static let height: CGFloat = 12

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
