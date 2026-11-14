import AppKit
import CmuxNextDesign

/// The quiet row a failed or disconnected mount draws in place of its scene (``AppSceneNativeView``).
///
/// A failure says what happened in plain words (``AppFailureCopy``): the title, then where and why for
/// a script error (`Line 2, column 12: expecting ';'`), then Copy Error and Details. The app host's raw
/// reason shows only under Details, selectable, and Copy Error puts it on the pasteboard whole. Reload
/// runs the app's saved script again (``AppSceneModel/reload()``). A
/// disconnected mount's reason is already plain words (the supervisor is unreachable): it draws as the
/// one line, with no buttons.
final class AppFailureNSView: NSView {
    private let title = ChromeLabel(wrappingLabelWithString: "")
    private let location = ChromeLabel(wrappingLabelWithString: "")
    private let raw = ChromeLabel(wrappingLabelWithString: "")
    private let reloadButton = AppFailureNSView.linkButton()
    private let copyButton = AppFailureNSView.linkButton()
    private let detailsButton = AppFailureNSView.linkButton()
    /// What Copy Error does with the raw reason: the general pasteboard; tests pass a recorder.
    private let copyText: @MainActor (String) -> Void
    private var shown: AppFailureCopy?
    private var detailsOpen = false

    init(copyText: @escaping @MainActor (String) -> Void = AppFailureNSView.copyToPasteboard) {
        self.copyText = copyText
        super.init(frame: .zero)
        title.font = Typography.caption
        title.maximumNumberOfLines = 2
        location.font = Typography.caption
        location.maximumNumberOfLines = 3
        location.isSelectable = true
        location.focusRingType = .none
        raw.font = Typography.system(.monospaced, size: Typography.caption.pointSize)
        raw.maximumNumberOfLines = 0
        raw.isSelectable = true
        raw.focusRingType = .none
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.themedToolTip = AppsStrings.reloadHelp
        copyButton.target = self
        copyButton.action = #selector(copyError)
        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails)
        for view in [title, location, raw, reloadButton, copyButton, detailsButton] as [NSView] { addSubview(view) }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `failure`'s words, or `disconnected`'s one plain line when the supervisor is unreachable.
    func show(failure: AppFailureCopy) {
        guard failure != shown else { return }
        shown = failure
        detailsOpen = false
        title.stringValue = failure.title
        location.stringValue = failure.location ?? ""
        raw.stringValue = failure.detail
        setTitle(reloadButton, AppsStrings.reload)
        setTitle(copyButton, AppsStrings.failureCopy)
        refreshVisibility(buttons: true)
    }

    /// The disconnected line: the reason alone, no buttons.
    func show(disconnected reason: String) {
        shown = nil
        detailsOpen = false
        title.stringValue = reason
        location.stringValue = ""
        raw.stringValue = ""
        refreshVisibility(buttons: false)
    }

    private func refreshVisibility(buttons: Bool) {
        location.isHidden = location.stringValue.isEmpty
        reloadButton.isHidden = !(buttons && onReload != nil)
        copyButton.isHidden = !buttons
        detailsButton.isHidden = !buttons
        raw.isHidden = !(buttons && detailsOpen)
        setTitle(detailsButton, detailsOpen ? AppsStrings.failureHideDetails : AppsStrings.failureDetails)
        needsLayout = true
    }

    @objc private func reload() { onReload?() }

    @objc private func copyError() {
        guard let detail = shown?.detail else { return }
        copyText(detail)
        setTitle(copyButton, AppsStrings.failureCopied)
    }

    @objc private func toggleDetails() {
        detailsOpen.toggle()
        refreshVisibility(buttons: true)
        onSizeChange?()
    }

    /// Reload's action: runs the app's script again. Nil hides Reload.
    var onReload: (@MainActor () -> Void)?

    /// Runs when Details opens or closes, so the host measures the row again.
    var onSizeChange: (() -> Void)?

    // MARK: Layout

    private var inset: CGFloat { Metrics.space4 }
    private var gap: CGFloat { Metrics.space1 }

    /// The row's height `width` points wide.
    func height(width: CGFloat) -> CGFloat {
        let inner = max(0, width - 2 * inset)
        var height = Metrics.space2 + ceil(title.size(forWidth: inner).height)
        if !location.isHidden { height += gap + ceil(location.size(forWidth: inner).height) }
        if !copyButton.isHidden { height += gap + ceil(copyButton.fittingSize.height) }
        if !raw.isHidden { height += gap + ceil(raw.size(forWidth: inner).height) }
        return height + Metrics.space2
    }

    override func layout() {
        super.layout()
        let inner = max(0, bounds.width - 2 * inset)
        var y = Metrics.space2
        func place(_ label: ChromeLabel) {
            let height = ceil(label.size(forWidth: inner).height)
            label.frame = CGRect(x: inset, y: y, width: inner, height: height)
            y += height + gap
        }
        place(title)
        if !location.isHidden { place(location) }
        if !copyButton.isHidden {
            var x = inset
            var rowHeight: CGFloat = 0
            for button in [reloadButton, copyButton, detailsButton] where !button.isHidden {
                let size = button.fittingSize
                button.frame = CGRect(x: x, y: y, width: ceil(size.width), height: ceil(size.height))
                x = button.frame.maxX + Metrics.space3
                rowHeight = max(rowHeight, ceil(size.height))
            }
            y += rowHeight + gap
        }
        if !raw.isHidden { place(raw) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    private func applyTheme() {
        performWithTheme {
            title.textColor = Palette.textSecondary
            location.textColor = Palette.textTertiary
            raw.textColor = Palette.textTertiary
        }
        for button in [reloadButton, copyButton, detailsButton] { setTitle(button, button.title) }
    }

    /// Copy Error's default: the raw reason on the general pasteboard, as plain text.
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A borderless text button in the caption font and the accent ink, sized to its title.
    private static func linkButton() -> ClickableButton {
        let button = ClickableButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = Typography.caption
        button.setButtonType(.momentaryChange)
        return button
    }

    private func setTitle(_ button: NSButton, _ text: String) {
        let color = performWithTheme { Palette.accent }
        button.title = text
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: Typography.caption, .foregroundColor: color])
        button.setAccessibilityLabel(text)
    }
}
