#if DEBUG
import AppKit

/// DEBUG ONLY (Environment Secrets Playground): any content that runs a closure on click (a radio row, a
/// scene pill, a list row), with no bezel of its own; a press dims its fill as the app's press-fill buttons do.
final class EnvClickArea: NSView {
    private let onPress: @MainActor (EnvClickArea) -> Void
    private var pressed = false { didSet { needsDisplay = true } }

    /// - Parameters:
    ///   - content: what the area draws; it fills the area.
    ///   - onPress: what a click (mouse up inside) runs, given the area (to anchor a menu).
    init(_ content: NSView, onPressIn onPress: @escaping @MainActor (EnvClickArea) -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// - Parameters:
    ///   - content: what the area draws; it fills the area.
    ///   - onPress: what a click (mouse up inside) runs.
    convenience init(_ content: NSView, onPress: @escaping @MainActor () -> Void) {
        self.init(content, onPressIn: { _ in onPress() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard pressed else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()  // radius-allow: a press highlight behind a playground row, not a button corner
    }

    /// Clicks go to the area, not to the labels inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress(self) }
    }
}
#endif
