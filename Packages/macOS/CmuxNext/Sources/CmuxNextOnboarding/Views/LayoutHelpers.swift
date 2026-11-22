import AppKit

extension NSColor {
    /// This color with its alpha multiplied by `factor`, resolved at draw
    /// time so theme colors stay live. (`withAlphaComponent` replaces the
    /// alpha, which turns a 6% hover fill into a 40% one.)
    func faded(_ factor: CGFloat) -> NSColor {
        NSColor(name: nil) { [self] _ in
            let resolved = usingColorSpace(.sRGB) ?? self
            return resolved.withAlphaComponent(resolved.alphaComponent * factor)
        }
    }
}

extension NSLayoutConstraint.Priority {
    /// Beats NSStackView's perpendicular pull (750), so a control hugs its
    /// content instead of stretching to the stack's width.
    static let hugsInStack = NSLayoutConstraint.Priority(760)
}

/// Takes the extra width in a horizontal stack so the controls before it
/// keep their natural size.
final class FlexibleSpace: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
