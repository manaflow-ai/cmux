public import AppKit
import CmuxNextDesign

/// The browser's omnibar row over a New Tab page (Lawrence 2026-11-23: "add the omnibar to the new tab
/// page"): the same ``OmnibarToolbarView`` a browser tab shows, with only the More (⋮) button after it.
/// No extension icons and none of the browser's other toolbar buttons: the page has no web page for
/// them to act on. The App puts it in the pane's `topBar`, which shows it only while the page is a New Tab page.
@MainActor public final class NewTabOmnibarBar: NSView {
    public static let identifier = "cmux.newTab.omnibar"
    public static let moreIdentifier = "cmux.newTab.omnibar.more"

    public let toolbar: OmnibarToolbarView
    let more: OverflowButton
    /// A commit: `beside` false loads the address in the page's tab, true opens it in another tab.
    public var open: (URL, _ beside: Bool) -> Void = { _, _ in }
    /// A Switch to Tab row: reveals tab `key`.
    public var switchToTab: (String) -> Void = { _ in }
    /// The More menu of the pane the page shows in.
    public var moreMenu: () -> NSMenu? = { nil }

    public init(suggestionEngine: OmniboxSuggestionEngine) {
        toolbar = OmnibarToolbarView(suggestionEngine: suggestionEngine)
        more = OverflowButton(label: Strings.toolbarMore)
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.identifier)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        more.translatesAutoresizingMaskIntoConstraints = false
        more.drawsPaneGlyph = true
        more.setAccessibilityIdentifier(Self.moreIdentifier)
        more.pressMenu = { [weak self] in self?.moreMenu() }
        addSubview(toolbar)
        addSubview(more)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor),
            more.leadingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space2),
            more.centerYAnchor.constraint(equalTo: toolbar.addressBar.centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: Metrics.space6),
            more.heightAnchor.constraint(equalToConstant: Metrics.space6),
        ])
        toolbar.addressBar.onEvent = { [weak self] event in self?.handle(event) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var preferredHeight: CGFloat { toolbar.preferredHeight }

    private func handle(_ event: OmnibarEvent) {
        switch event {
        case .didEndEditing(.commit(let url)): open(url, false)
        case .didEndEditing(.open(let url, _)): open(url, true)
        case .didEndEditing(.switchToTab(let key)): switchToTab(key)
        case .didBeginEditing, .didEndEditing(.cancel), .didEndEditing(.blur), .didEndEditing(.keyword): break
        }
    }
}
