public import AppKit
package import CmuxNextRemoteView

#if DEBUG
/// Receives the page view's keyboard and pointer events (the remote tab).
@MainActor
public protocol RemoteBrowserEventTarget: AnyObject {
    @discardableResult
    func handleKeyEquivalent(_ event: NSEvent) -> Bool
    func handleKey(_ event: NSEvent)
    func handlePointer(_ event: NSEvent)
}

/// The page area of a remote tab: decoded frames at 1:1 device pixels. The
/// browser chrome around it (tab strip, omnibar, find) is the local cmux UI
/// (RT11); only the page is remote. Its events go to `eventTarget`.
public final class RemoteBrowserContentView: NSView {
    package let video = RemoteVideoView()
    public weak var eventTarget: (any RemoteBrowserEventTarget)?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        video.autoresizingMask = [.width, .height]
        video.frame = bounds
        addSubview(video)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only while the page has keyboard focus: other views keep their chords.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let eventTarget else { return false }
        return eventTarget.handleKeyEquivalent(event)
    }

    public override func keyDown(with event: NSEvent) { eventTarget?.handleKey(event) }
    public override func keyUp(with event: NSEvent) { eventTarget?.handleKey(event) }
    public override func flagsChanged(with event: NSEvent) { eventTarget?.handleKey(event) }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        eventTarget?.handlePointer(event)
    }

    public override func mouseUp(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func mouseDragged(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func mouseMoved(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func rightMouseDown(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func rightMouseUp(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func otherMouseDown(with event: NSEvent) { eventTarget?.handlePointer(event) }
    public override func otherMouseUp(with event: NSEvent) { eventTarget?.handlePointer(event) }
}
#endif
