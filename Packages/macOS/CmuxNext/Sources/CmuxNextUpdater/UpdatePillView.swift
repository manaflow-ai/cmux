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
        label.font = Typography.bodyEmphasized
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

    /// The capsule's width for `text` at `height`: the label, a half-height
    /// cap at each end, and room for the material's own content inset.
    public func fittingWidth(height: CGFloat) -> CGFloat {
        (label.intrinsicContentSize.width + height + Metrics.space2 * 2).rounded(.up)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        surface.frame = bounds
        surface.cornerRadius = bounds.height / 2
        // Glass lays `contentView` out itself (it may be inset): center in it.
        surface.layoutSubtreeIfNeeded()
        let box = surface.contentView.bounds
        let size = label.intrinsicContentSize
        let width = min(size.width.rounded(.up), box.width)
        label.frame = CGRect(x: ((box.width - width) / 2).rounded(), y: ((box.height - size.height) / 2).rounded(),
                             width: width, height: size.height)
        performWithTheme { label.textColor = Palette.textPrimary }
    }
}
