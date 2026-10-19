public import AppKit
import CmuxNextDesign

/// The location bar of a popup window, after Chromium's `LocationBarView`
/// in popup mode (`is_popup_mode_`, `ToolbarView::DisplayMode::LOCATION`):
/// the page-info chip (security icon, "Not Secure" or "Dangerous" text)
/// and the page's URL. The URL can be selected and copied but not edited
/// (Chromium makes the popup omnibox read-only), and there are no page
/// actions, suggestions or bookmark star. The chip opens page info, as in
/// a tab's omnibar. Like Chromium's popup location bar it spans the
/// window as a flat band (`RefreshBackground` paints a solid rectangle in
/// popup mode, not the rounded omnibox). Clicking the URL shows it in full,
/// selected, as clicking Chromium's read-only omnibox un-elides it.
public final class PopupLocationBarView: NSView {
    /// Space before the chip and after the text.
    static let sideInset: CGFloat = 6

    private let tab: any BrowserTab
    private let chip = PageInfoChipButton()
    /// Read-only, selectable URL text.
    let field = PopupAddressField(labelWithString: "")
    private var observation: ObservationLoop?
    private lazy var pageInfo = PageInfoController(tab: { [weak self] in self?.tab }, anchor: { [weak self] in self?.chip })
    private var shown: (url: URL?, security: BrowserSecurityState)?

    /// A bar that follows `tab`'s URL and security.
    public init(tab: any BrowserTab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.onPress = { [weak self] in self?.pageInfo.toggle() }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isSelectable = true
        field.isEditable = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(Strings.popupAddress)
        field.setAccessibilityIdentifier("cmux.browserPopup.address")
        field.onEditingChange = { [weak self] _ in self?.applyText() }
        addSubview(chip)
        addSubview(field)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: OmnibarStyle.chipSize),
            field.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: OmnibarStyle.textLeading),
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.sideInset),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.browserPopup.locationBar")
        observation = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text the bar shows (`BrowserURLDisplay`, the omnibar's rules).
    public var displayedText: String { field.stringValue }

    /// Stops following the page and closes its page info bubble.
    public func stop() {
        observation?.cancel()
        observation = nil
        pageInfo.tabDidChange()
    }

    private func render() {
        let state = tab.state
        let security = PageInfoSite.omnibarSecurity(for: state)
        let site = PageInfoSite(state: state)
        chip.indicator = PageInfoIndicator.resolve(site: site, isFocused: false, editingSymbol: nil)
        let url = site.url ?? state.url
        guard shown.map({ $0.url != url || $0.security != security }) ?? true else { return }
        shown = (url, security)
        applyText()
    }

    // theme-scoped: reads Palette through OmnibarStyle inside performWithTheme
    private func applyText() {
        let url = shown?.url ?? nil
        if field.isShowingFullText {
            // The user clicked the URL: the whole address, selected.
            field.showFullText(BrowserURLDisplay.editingText(for: url))
            return
        }
        let text = BrowserURLDisplay.displayText(for: url)
        performWithTheme {
            let font = OmnibarStyle.font
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: OmnibarStyle.textSecondary,
            ])
            let host = BrowserURLDisplay.hostRange(in: text, for: url) ?? NSRange(location: 0, length: (text as NSString).length)
            attributed.addAttribute(.foregroundColor, value: OmnibarStyle.textPrimary, range: host)
            field.attributedStringValue = attributed
            layer?.backgroundColor = OmnibarStyle.barFill(.rest, coverage: 1).cgColor
        }
        field.toolTip = url?.absoluteString
    }

    /// Repaints with the window's current theme.
    public func applyTheme() {
        applyText()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyText()
    }
}
