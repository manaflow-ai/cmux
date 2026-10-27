import AppKit
import CmuxNextInput
import CmuxNextWakeups

/// An invisible full-size subview of the region: it owns the tracking area
/// and follows the region's window (focus changes, close). It takes no
/// clicks and draws nothing.
final class HoverRevealProbe: NSView {
    weak var owner: HoverReveal? {
        didSet { ownerKey = owner.map { ObjectIdentifier($0) } }
    }
    /// The owner's identity, for leaving the focus router after the owner went away.
    private var ownerKey: ObjectIdentifier?
    /// The window whose focus router this probe's owner joined.
    private weak var routedWindow: NSWindow?
    private let trackingOptions: NSTrackingArea.Options
    private let tracksPointer: Bool
    /// The window's close, through its ``WindowEvents`` (one observer per notice for the window).
    private var closeObserver: EventSubscription?
    /// The moves inside, on its window's FrameInputCoalescer (feature `pointerFrameHover`, its window's
    /// ``HoverFrameInputHosting`` frames): a move marks a pointer inside whose enter was missed, on its frame interval's leading edge or once at the frame.
    private(set) lazy var frameInput = PointerFrameHover(owner: "HoverRevealProbe", view: self) { [weak self] _ in
        if self?.owner?.state.pointerInside == false { self?.owner?.setPointerInside(true) }
    }

    init(tracking: NSTrackingArea.Options, tracksPointer: Bool) {
        trackingOptions = tracking
        self.tracksPointer = tracksPointer
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            closeObserver?.cancel()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let own = trackingAreas.filter { $0.owner === self }
        // An unchanged rect keeps its area. Replacing it on every call (each layout pass of the
        // sidebar slide) dropped an exit that arrived between the removal and the new area, and the
        // new area, added with the pointer already outside, never reported it, so the reveal stayed
        // on (Lawrence 2026-10-05, nxdog55: the window controls with the sidebar closed).
        if tracksPointer, own.count == 1, own[0].rect == bounds { return }
        for area in own { removeTrackingArea(area) }
        guard tracksPointer else { return }
        // Exactly the bounds, not `.inVisibleRect`: the visible rect of a view that does not clip
        // reaches past its bounds (nxdog43: the whole window), so the pointer never "left" until it
        // left the window. AppKit calls this again whenever the bounds change.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, trackingOptions], owner: self))
        // A new area cannot know an exit the old one missed: read where the pointer is now.
        readPointer()
    }

    /// Sets "inside" from the pointer's position now. A window that is not
    /// shown cannot be under the pointer, and an `.activeForHover` region
    /// takes no pointer while another app is active.
    private func readPointer() {
        guard tracksPointer, let window, let owner else { return }
        let tracksNow = trackingOptions.tracksWhileInactive || PointerHover.appShowsHover
        let inside = window.isVisible && tracksNow && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if inside != owner.state.pointerInside { owner.setPointerInside(inside) }
    }

    /// The tracked rect follows the bounds even when the visible rect does not change.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        frameInput.flush()
        owner?.setPointerInside(true)
    }
    override func mouseMoved(with event: NSEvent) { frameInput.moved(event) }
    override func mouseExited(with event: NSEvent) {
        // A move from before the exit would only mark the pointer inside again.
        frameInput.cancel()
        owner?.setPointerInside(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow !== window else { return }
        if let routedWindow, let ownerKey { HoverRevealFocusRouter.leave(ownerKey, window: routedWindow) }
        routedWindow = nil
        closeObserver?.cancel()
        closeObserver = nil
        owner?.windowWillChange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameInput.frames = (window as? HoverFrameInputHosting)?.hoverFrameInput
        guard let window else { return }
        if let owner {
            HoverRevealFocusRouter.join(owner, window: window)
            routedWindow = window
        }
        // Ended when the probe leaves the window or deinits; runs in the close's own turn.
        closeObserver = WindowEvents.of(window).subscribe(NSWindow.willCloseNotification, owner: "HoverRevealProbe") { [weak self, weak window] in
            guard let window else { return }
            if let key = self?.ownerKey { HoverRevealFocusRouter.forgetFocus(key, window: window) }
            self?.owner?.windowWillChange()
        }
        // A pointer already over the region when it joins a shown window
        // reveals at once, before any click (no mouseEntered arrives for
        // it). A window that is not on screen cannot be under the pointer.
        readPointer()
    }
}
