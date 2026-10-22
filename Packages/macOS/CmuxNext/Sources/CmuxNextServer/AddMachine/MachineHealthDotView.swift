import AppKit
import CmuxNextDesign

/// A filled circle in a theme color read in the view's theme scope (a machine's warning or
/// failing last check). A layer, so it costs no draw pass.
final class MachineHealthDotView: NSView {
    private let diameter: CGFloat
    private let color: @MainActor () -> NSColor

    init(diameter: CGFloat, color: @escaping @MainActor () -> NSColor) {
        self.diameter = diameter
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme { layer?.backgroundColor = color().cgColor }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}
