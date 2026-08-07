import AppKit
import QuartzCore

/// Layer-backed opaque-window fill installed below the hosting and portal trees.
@MainActor
final class WindowRootBackdropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("cmux.windowRootBackdrop")
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        layer?.isOpaque ?? false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Applies the resolved opaque root policy without enabling Core Image compositing.
    func apply(policy: WindowBackdropPolicy) {
        let color: NSColor
        switch policy {
        case let .ghosttyTerminalBackdrop(backgroundColor, opacity, _):
            let clampedOpacity = WindowAppearanceSnapshot.clampedOpacity(Double(opacity))
            let backdropColor = backgroundColor.withAlphaComponent(clampedOpacity)
            color = clampedOpacity >= 1
                ? backdropColor
                : WindowChromeColorResolver().compositedColor(backdropColor, over: .windowBackgroundColor)
        case .sidebarMaterial, .clear:
            color = .clear
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = color.cgColor
        layer?.isOpaque = color.alphaComponent >= 1
        CATransaction.commit()
    }
}
