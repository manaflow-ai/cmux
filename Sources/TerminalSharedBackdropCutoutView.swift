import AppKit

/// A permanent pre-display compositing node for pane-local terminal backgrounds.
final class TerminalSharedBackdropCutoutView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCompositing()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCompositing()
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Toggles whether this already-realized node subtracts the shared backdrop.
    func setClearingSharedBackdrop(_ clearsSharedBackdrop: Bool) {
        isHidden = !clearsSharedBackdrop
    }

    private func configureCompositing() {
        let cutoutFilter = TerminalSharedBackdropCutoutFilter()
        cutoutFilter.name = "terminalSharedBackdropCutout"

        wantsLayer = true
        layerUsesCoreImageFilters = true
        compositingFilter = cutoutFilter
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.isOpaque = true
        isHidden = true
    }
}
