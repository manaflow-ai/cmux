import AppKit
import CmuxNextDesign

/// The standard titlebar strip (`window.titlebar` "standard") above the
/// content column: the workspace title, centered, secondary text. Dragging
/// it moves the window; a double-click runs the user's titlebar action
/// (both through `TitlebarDragPolicy`).
final class TitlebarView: NSView, TitlebarPressDeciding {
    private let label = NSTextField(labelWithString: "")

    var title: String = "" {
        didSet { label.stringValue = title }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.bodyEmphasized
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space5),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { label.textColor = Palette.textSecondary }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
    }

    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .movesWindow }
}
