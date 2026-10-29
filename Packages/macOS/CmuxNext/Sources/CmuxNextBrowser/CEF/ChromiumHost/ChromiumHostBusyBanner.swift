import AppKit
import CmuxNextDesign

/// "Chromium is busy", with Wait and Reload Chromium: the bar across the top of a pane that shows a
/// hosted page while ``ChromiumHostHangMonitor/isBusy``. Chrome asks the same
/// of a page whose renderer stopped answering (`HungRendererDialogView`, Wait and Exit page); here the
/// Chromium Host's UI thread is what stopped, so the bar names Chromium and its reload restarts the
/// host. Wait gives the host another two seconds; the bar goes by itself when the host takes input
/// again.
final class ChromiumHostBusyBanner: NSView {
    /// The bar's height.
    static let height: CGFloat = 32

    private let label = ChromeLabel(labelWithString: Strings.chromiumHostBusy)
    private let waitButton = NSButton(title: Strings.chromiumHostBusyWait, target: nil, action: nil)
    private let reloadButton = NSButton(title: Strings.chromiumHostBusyReload, target: nil, action: nil)
    private let onWait: () -> Void
    private let onReload: (() -> Void)?

    /// - Parameters:
    ///   - wait: The Wait button.
    ///   - reload: The Reload Chromium button; nil shows no such button (a supervisor that cannot end its host).
    init(wait: @escaping () -> Void, reload: (() -> Void)?) {
        onWait = wait
        onReload = reload
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        for button in [waitButton, reloadButton] {
            button.isBordered = false
            button.target = self
            button.font = .systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis)
        }
        waitButton.action = #selector(waitPressed)
        reloadButton.action = #selector(reloadPressed)
        addSubview(waitButton)
        if reload != nil { addSubview(reloadButton) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.chromiumHostBusy)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    /// The banner's place in `container`: its full width at the top, kept there as it resizes.
    func place(in container: NSView) {
        let bounds = container.bounds
        frame = CGRect(x: bounds.minX, y: bounds.maxY - Self.height, width: bounds.width, height: Self.height)
        autoresizingMask = [.width, .minYMargin]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsDisplay = true // invalidate: draw(_:) fills with the new appearance's colors
    }

    private func applyColors() {
        performWithTheme {
            label.textColor = Palette.textPrimary
            for button in [waitButton, reloadButton] {
                button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                    .foregroundColor: Palette.textSecondary,
                    .font: NSFont.systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis),
                ])
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.chromeBackground.setFill()
            bounds.fill()
            Palette.separator.setFill()
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
        }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let spacing: CGFloat = 12
        var right = bounds.maxX - inset
        for button in [reloadButton, waitButton] where button.superview === self {
            let size = button.intrinsicContentSize
            right -= size.width
            button.frame = CGRect(x: right.rounded(), y: (bounds.midY - size.height / 2).rounded(), width: size.width, height: size.height)
            right -= spacing
        }
        let height = label.intrinsicContentSize.height
        let width = max(0, min(label.intrinsicContentSize.width, right - bounds.minX - inset))
        label.frame = CGRect(x: bounds.minX + inset, y: (bounds.midY - height / 2).rounded(), width: width, height: height)
    }

    @objc private func waitPressed() { onWait() }

    @objc private func reloadPressed() { onReload?() }
}
