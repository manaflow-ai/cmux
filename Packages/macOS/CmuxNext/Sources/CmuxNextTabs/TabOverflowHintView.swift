public import AppKit
import CmuxNextDesign

/// The one-time hint at the trailing end of a tab strip whose unpinned tabs reached their minimum width
/// in Shrink mode (cx-kp9b4, Lawrence 2026-10-15: "make it intuitive for user to enable scrolling tabs"):
/// "Tabs are at their minimum width. Use scrolling tabs?", Use Scrolling Tabs and a dismiss x. Either
/// button ends it for good: the choice is recorded in UserDefaults (as the browser fit line records
/// `cmux.next.browser.fitExplained`), and only one strip shows it at a time. A strip that stops being
/// crowded hides it without recording, so it can come back until the person answers it.
public final class TabOverflowHintView: NSView {
    /// Where the once-ever flag lives; a test passes its own suite.
    public static var defaults = UserDefaults.standard
    static let answeredKey = "cmux.next.tabs.overflowHintAnswered"
    /// The hint was answered (Use Scrolling Tabs, the x, or scrolling tabs turned on while it showed).
    static var isAnswered: Bool { defaults.bool(forKey: answeredKey) }
    /// The strip that shows the hint.
    static weak var owner: TabStripView?

    /// Runs after a button: `true` for Use Scrolling Tabs.
    var onAnswer: ((_ usesScrolling: Bool) -> Void)?

    let label = NSTextField(labelWithString: Strings.overflowHint)
    let useButton = NSButton(title: Strings.overflowHintUse, target: nil, action: nil)
    let dismissButton = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        label.toolTip = Strings.overflowHint
        useButton.isBordered = false
        useButton.target = self
        useButton.action = #selector(useScrolling)
        dismissButton.isBordered = false
        dismissButton.imagePosition = .imageOnly
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        dismissButton.setAccessibilityLabel(Strings.overflowHintDismiss)
        dismissButton.toolTip = Strings.overflowHintDismiss
        for view in [label, useButton, dismissButton] as [NSView] { addSubview(view) }
        applyTokens()
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTokens() {
        label.font = Typography.caption
        useButton.font = Typography.system(size: Typography.caption.pointSize, weight: TypeScale.emphasis)
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: Strings.overflowHintDismiss)?
            .withSymbolConfiguration(.init(pointSize: Typography.caption.pointSize - 2, weight: .semibold))
        needsLayout = true
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        useButton.contentTintColor = performWithTheme { Palette.accent }
        dismissButton.contentTintColor = performWithTheme { Palette.textSecondary }
    }

    /// The width the hint asks for: the sentence, the button, the x and the gaps between them.
    var preferredWidth: CGFloat {
        let gap = Metrics.space3
        return (label.intrinsicContentSize.width + gap + useButton.intrinsicContentSize.width + Metrics.space2 + dismissSide + gap).rounded(.up)
    }

    private var dismissSide: CGFloat { Metrics.space6 }

    public override func layout() {
        super.layout()
        let gap = Metrics.space3
        let height = bounds.height
        func centered(_ view: NSView, x: CGFloat, width: CGFloat) {
            let h = min(view.intrinsicContentSize.height, height)
            view.frame = CGRect(x: x, y: ((height - h) / 2).rounded(), width: max(0, width), height: h)
        }
        let dismissX = bounds.width - gap - dismissSide
        dismissButton.frame = CGRect(x: dismissX, y: ((height - dismissSide) / 2).rounded(), width: dismissSide, height: dismissSide)
        let useWidth = useButton.intrinsicContentSize.width
        let useX = dismissX - Metrics.space2 - useWidth
        centered(useButton, x: useX, width: useWidth)
        centered(label, x: gap, width: useX - 2 * gap)
    }

    @objc private func useScrolling() { onAnswer?(true) }
    @objc private func dismiss() { onAnswer?(false) }
}
