public import AppKit
public import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign

/// The window of one popup page (`window.open` with window features: OAuth
/// sign-in, payment, an extension's popup window), built like Chrome's
/// `Browser::TYPE_POPUP` window on macOS:
///
/// - An independent top-level window, not a child of its opener's window
///   (`BrowserWidget::InitBrowserWidget` sets no parent): it moves, hides
///   and minimizes on its own, appears in the Window menu, and stays open
///   when the opener closes.
/// - The system title bar with the page title and all three traffic lights
///   in their standard place (`BrowserNativeWidgetMac` uses
///   `Titled|Closable|Miniaturizable|Resizable`;
///   `BrowserFrameViewMac::GetCaptionButtonBounds` is empty for popups).
/// - A toolbar that is only the location bar
///   (`ToolbarView::DisplayMode::kLocation`, `kLocationBarHeight` 34 pt),
///   then a 1 pt separator and the page. The location bar is the browser
///   tab's omnibar (`OmnibarToolbarView`/`AddressBarView`, the same view,
///   chip, URL styling, selection, suggestions and keys; user, 2026-10-19:
///   "omnibar for popover web windows need to reuse the same omnibar code").
///   A page popup's address is editable like a tab's; a system sign-in
///   window's is read-only (`readOnlyAddress`).
/// - Fullscreen hides the location bar (`PopupBrowserSupportsWindowFeature`).
/// - Escape stops a load and never closes the window
///   (`IDC_CLOSE_FIND_OR_STOP`); Cmd-W and `window.close()` close it.
public final class BrowserPopupWindow: NSWindow {
    /// The toolbar under the title bar: the location bar, with the 1 pt
    /// separator to the page inside it so the page gets the size it asked for.
    static let toolbarHeight: CGFloat = 34
    static let separatorHeight: CGFloat = 1
    static let styles: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    /// The system title bar's height for this style (Chrome does not hard-code it).
    static var titlebarHeight: CGFloat {
        let content = CGRect(x: 0, y: 0, width: 400, height: 400)
        return NSWindow.frameRect(forContentRect: content, styleMask: styles.subtracting(.fullSizeContentView)).height - content.height
    }

    /// Everything above the page: the title bar and the toolbar.
    public static var chromeHeight: CGFloat { titlebarHeight + toolbarHeight }

    public let page: any BrowserTab
    public var onClose: (() -> Void)?
    /// Set for a system sign-in window (`WebAuthSessionWindow`), where
    /// Escape cancels like the system sheet's Cancel button; a page's popup
    /// leaves it nil and follows Chrome.
    public var onEscape: (() -> Void)?
    /// The toolbar row: the browser tab's omnibar.
    public let locationBar: OmnibarToolbarView
    /// The omnibar of the row.
    public var addressBar: AddressBarView { locationBar.addressBar }
    /// Connects the omnibar to the page (URL, security, page info, loads).
    public let omnibar: OmnibarTabBinding
    private var observation: Task<Void, Never>?
    private let separator = NSBox()
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var fullscreenObservers: [MainActorObservation] = []

    /// A popup window showing `page`.
    ///
    /// - Parameters:
    ///   - page: The popup's page.
    ///   - frame: The window frame.
    ///   - suggestionEngine: The omnibar's suggestions (the opener profile's
    ///     engine; a fresh one in tests).
    ///   - readOnlyAddress: True for a system sign-in window, whose address
    ///     can be selected and copied but not edited (navigating away would
    ///     lose the sign-in).
    public init(page: any BrowserTab, frame: CGRect, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine(),
                readOnlyAddress: Bool = false) {
        self.page = page
        locationBar = OmnibarToolbarView(suggestionEngine: suggestionEngine)
        locationBar.addressBar.isReadOnly = readOnlyAddress
        locationBar.addressBar.setAccessibilityIdentifier(Self.omnibarIdentifier)
        omnibar = OmnibarTabBinding(addressBar: locationBar.addressBar, tab: page)
        super.init(contentRect: frame, styleMask: Self.styles, backing: .buffered, defer: false)
        setFrame(frame, display: false)
        isReleasedWhenClosed = false
        isRestorable = false
        titleVisibility = .visible
        titlebarAppearsTransparent = true
        tabbingMode = .disallowed
        collectionBehavior.insert(.fullScreenPrimary)
        contentMinSize = CGSize(width: BrowserPopupWindowGeometry.minimumContent, height: Self.toolbarHeight + 1)
        animationBehavior = Motion.panes.animatesMovement ? .documentWindow : .none
        // Kind `.browserPopup`: the three traffic lights and the one surface
        // background; the opener's scope is adopted when it opens.
        install(kind: .browserPopup, content: makeContent(), scope: .app)
        title = Self.title(for: page.state)
        observeTitle()
        observeFullscreen()
    }

    /// Page title, live.
    private func observeTitle() {
        let page = page
        observation = Task { [weak self] in
            for await state in ObservationStream({ page.state }) {
                self?.title = Self.title(for: state)
            }
        }
    }

    /// Chrome's popup window title: the page title alone (no app name on
    /// macOS, `WindowMetadataController::GetWindowTitleFromWebContents`),
    /// else the address as the location bar shows it
    /// (`NavigationEntryImpl::GetTitleForDisplay`), else "Untitled".
    /// The popup omnibar's accessibility identifier (UI tests, `debug.popups`).
    public static let omnibarIdentifier = "cmux.browserPopup.omnibar"

    public static func title(for state: BrowserTabState) -> String {
        if let title = state.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let address = BrowserURLDisplay.displayText(for: state.url)
        return address.isEmpty ? PopupStrings.popupUntitled : address
    }

    private func makeContent() -> NSView {
        let root = ThemeChangeView()
        root.onThemeChange = { [weak self] in self?.applyColors() }
        locationBar.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.translatesAutoresizingMaskIntoConstraints = false
        let pageView = page.contentView
        pageView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(locationBar)
        root.addSubview(separator)
        root.addSubview(pageView)
        let height = locationBar.heightAnchor.constraint(equalToConstant: Self.locationRowHeight)
        toolbarHeightConstraint = height
        let top = locationBar.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.titlebarHeight + Self.omnibarTopGap)
        topInset = top
        NSLayoutConstraint.activate([
            // The content reaches the window top so the backdrop paints
            // behind the title bar; the toolbar starts under it.
            top,
            locationBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            locationBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            height,
            separator.topAnchor.constraint(equalTo: locationBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: Self.separatorHeight),
            pageView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            pageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Space above the omnibar pill inside the 34 pt toolbar: the pill (28 pt,
    /// the tab omnibar's height) sits centered between the title bar and the
    /// separator.
    static let omnibarTopGap: CGFloat = 3
    /// The omnibar row under `omnibarTopGap`, down to the separator.
    static var locationRowHeight: CGFloat { toolbarHeight - separatorHeight - omnibarTopGap }

    /// The location bar's distance from the window top (the title bar; 0 in
    /// fullscreen, where the title bar slides away).
    private var topInset: NSLayoutConstraint?

    /// Theme colors of the opener's scope (adopted when the popup opens).
    private func applyColors() {
        guard let root = contentView else { return }
        root.performWithTheme {
            separator.fillColor = Palette.separator
        }
    }

    /// Fullscreen shows only the page (Chrome hides a popup's location bar there).
    private func observeFullscreen() {
        let center = NotificationCenter.default
        for (name, isFull) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
            fullscreenObservers.append(MainActorObservation(name, object: self, center: center) { [weak self] in
                self?.showToolbar(!isFull)
            })
        }
    }

    /// Shows or hides the title bar gap, the location bar and its separator.
    public func showToolbar(_ shown: Bool) {
        locationBar.isHidden = !shown
        separator.isHidden = !shown
        toolbarHeightConstraint?.constant = shown ? Self.locationRowHeight : 0
        topInset?.constant = shown ? Self.titlebarHeight + Self.omnibarTopGap : 0
    }

    public var isToolbarShown: Bool { !locationBar.isHidden }

    /// Escape the page did not use stops a load (Chrome's
    /// `IDC_CLOSE_FIND_OR_STOP`); it never closes the popup, so an Escape
    /// in a sign-in form cannot lose it.
    override public func cancelOperation(_ sender: Any?) {
        if let onEscape { return onEscape() }
        if page.state.isLoading { page.stop() }
    }

    /// Cmd-L (`focusBrowserAddressBar`) while the popup or its page has the
    /// keyboard: the omnibar gets it with the whole address selected, as a
    /// tab's does (a sign-in window's read-only bar too: select and copy).
    /// A Chromium page window holding the keyboard gives it back first.
    public func focusAddressBar() {
        if isVisible, !isKeyWindow { makeKey() }
        addressBar.focus()
    }

    /// Every close path (close button, Cmd-W, `window.close()`) ends here once.
    override public func close() {
        observation?.cancel()
        observation = nil
        fullscreenObservers.removeAll()
        omnibar.stop()
        let closed = onClose
        onClose = nil
        super.close()
        closed?()
    }
}
