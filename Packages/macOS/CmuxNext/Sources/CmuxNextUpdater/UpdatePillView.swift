public import AppKit
import CmuxNextDesign

/// The capsule beside the update circle: "Installing…" while the update
/// installs and relaunches, or a short note ("cmux Is Up to Date") that
/// hides itself. A floating overlay panel (glass, or the opaque fill under
/// Reduce Transparency); it never takes clicks.
@MainActor
public final class UpdatePillView: NSView {
    private let surface = Glass.makeOverlayPanel(interactive: false)
    private let label = NSTextField(labelWithString: "")

    public override init(frame: NSRect) {
        super.init(frame: frame)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        label.font = Metrics.bodyEmphasized
        label.lineBreakMode = .byTruncatingTail
        surface.contentView.addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    public var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            needsLayout = true
        }
    }

    /// The capsule's size for `text` at `height`.
    public func fittingWidth(height: CGFloat) -> CGFloat {
        (label.intrinsicContentSize.width + height).rounded(.up)
    }

    override public func layout() {
        super.layout()
        surface.frame = bounds
        surface.cornerRadius = bounds.height / 2
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: bounds.height / 2, y: ((bounds.height - size.height) / 2).rounded(),
                             width: max(0, bounds.width - bounds.height), height: size.height)
        performWithTheme { label.textColor = Palette.textPrimary }
    }
}
