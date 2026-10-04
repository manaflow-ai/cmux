import AppKit
import CmuxNextDesign

/// cmux's header over Chromium's side panel (`CEFSidePanelState`): icon,
/// title and the controls Chromium's header shows (pin to the toolbar, open
/// in a new tab, more info, close), in theme colors. Each control runs
/// Chromium's own button through `onPress`.
final class SidePanelHeaderView: NSView {
    var onPress: ((CEFSidePanelState.Control) -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private lazy var pin = ChromeIconButton(symbol: "pin", label: Strings.sidePanelPin, action: #selector(pressPin), target: self)
    private lazy var openInNewTab = ChromeIconButton(symbol: "arrow.up.forward.square", label: Strings.sidePanelOpenInNewTab,
                                                     action: #selector(pressOpenInNewTab), target: self)
    private lazy var moreInfo = ChromeIconButton(symbol: "ellipsis", label: Strings.sidePanelMoreInfo,
                                                 action: #selector(pressMoreInfo), target: self)
    private lazy var close = ChromeIconButton(symbol: "xmark", label: Strings.sidePanelClose, action: #selector(pressClose), target: self)
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("browser.sidePanel.header")
        icon.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, title, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        stack.orientation = .horizontal
        stack.spacing = 2
        for button in [pin, openInNewTab, moreInfo, close] { stack.addArrangedSubview(button) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ state: CEFSidePanelState) {
        title.stringValue = state.title
        setAccessibilityLabel(state.title)
        icon.image = state.icon.flatMap(NSImage.init(data:))
        icon.isHidden = icon.image == nil
        pin.isHidden = !state.showsPin
        pin.setSymbol(state.isPinned ? "pin.fill" : "pin", label: state.isPinned ? Strings.sidePanelUnpin : Strings.sidePanelPin)
        openInNewTab.isHidden = !state.showsOpenInNewTab
        moreInfo.isHidden = !state.showsMoreInfo
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    /// In this view's theme scope (a room or workspace may have its own theme).
    private func updateColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.pageBackground.cgColor
            title.textColor = Palette.textPrimary
        }
    }

    @objc private func pressPin() { onPress?(.pin) }
    @objc private func pressOpenInNewTab() { onPress?(.openInNewTab) }
    @objc private func pressMoreInfo() { onPress?(.moreInfo) }
    @objc private func pressClose() { onPress?(.close) }
}
