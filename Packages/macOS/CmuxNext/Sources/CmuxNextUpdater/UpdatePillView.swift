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
        label.alignment = .center
        label.lineBreakMode = .byClipping
        // Above the material, not in its content view: glass lays that view
        // out (inset) itself, which truncated the label.
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    var cornerRadius: CGFloat { surface.cornerRadius }

    public var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            needsLayout = true
        }
    }

    /// The capsule's width for `text` at `height`: the text measured in the
    /// label's font (the field's intrinsic width fell about 10 pt short in
    /// window snapshots, ending in an ellipsis), the field's cell padding,
    /// and a half-height cap at each end.
    public func fittingWidth(height: CGFloat) -> CGFloat {
        let font = label.font ?? Typography.bodyEmphasized
        let text = (label.stringValue as NSString).size(withAttributes: [.font: font]).width
        return (max(text, label.intrinsicContentSize.width) + Metrics.space2 * 2 + height).rounded(.up)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        surface.frame = bounds
        surface.cornerRadius = bounds.height / 2
        // The full width, text centered: the capsule already fits the text.
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
        performWithTheme { label.textColor = Palette.textPrimary }
    }
}
