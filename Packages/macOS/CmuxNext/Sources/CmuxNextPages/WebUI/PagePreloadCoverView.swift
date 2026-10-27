import AppKit
import CmuxNextWakeups
import QuartzCore

/// A claimed page's cover (``PagePreloadSlot``): the frame it painted while parked, at the size it
/// painted, on top of the page until its first live frame or the slot's ``PagePreloadSlot/coverLimit``.
///
/// Its layer never animates (p13-webui.md 4.4): every write to it runs with actions disabled. The
/// layer's own `actions` would not do: its delegate, this view, is asked first and answers an
/// animation inside an implicit-animation group. It is out of the mouse's and accessibility's way.
final class PagePreloadCoverView: NSView {
    private let image: CGImage
    /// The deadline that takes the cover off when no live frame comes; cancelled when it goes.
    var limit: MainDeadline?

    init(image: CGImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Made at the claim's size (the slot shows no cover of another size); a later resize brings
        // the page's own frame, which takes the cover off.
        autoresizingMask = [.width, .height]
        PagePreloadSlot.withoutActions {
            layer?.contentsGravity = .resize
            // Now, so the picture is in the claim's frame; `updateLayer` sets it again on a redisplay.
            layer?.contents = image
        }
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        PagePreloadSlot.withoutActions { layer?.contents = image }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let scale = window?.backingScaleFactor else { return }
        PagePreloadSlot.withoutActions { layer?.contentsScale = scale }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// Takes the cover off, with no animation.
    func remove() {
        limit?.cancel()
        limit = nil
        PagePreloadSlot.withoutActions { removeFromSuperview() }
    }
}
