public import AppKit
import CmuxNextDesign

/// The browser toolbar's omnibar row for a surface that is not a browser page: the New Tab page
/// shows it on top (cx-e2aa), so Cmd-L there types an address in the same omnibar a browser tab
/// has (one implementation: `AddressBarView`, its suggestions and its state machine). The bar sits
/// at the toolbar's height, top padding and side insets; its suggestion card opens flush under it,
/// clipped to `cardClip`. The cursor follows the browser toolbar's rules (`ArrowCursorView`,
/// `OmnibarPointer`).
///
/// With `navigation` the row also has the browser toolbar's Back, Forward and Reload buttons, at
/// the browser's place and size, for a surface that navigates like a page (the Markdown tab). The
/// owner says what they do (``onBack``, ``onForward``, ``onReload``) and when they are enabled
/// (``setNavigation(canGoBack:canGoForward:canReload:)``).
public final class OmnibarToolbarView: ArrowCursorView {
    public let addressBar: AddressBarView
    /// The surface the suggestion card is clipped to (the page under the row); the window when nil.
    public weak var cardClip: NSView?
    /// Back, Forward and Reload; nil without `navigation`.
    public var backButton: NSButton? { back }
    public var forwardButton: NSButton? { forward }
    public var reloadButton: NSButton? { reload }
    /// What Back, Forward and Reload do; each runs only while its button is enabled.
    public var onBack: (() -> Void)?
    public var onForward: (() -> Void)?
    public var onReload: (() -> Void)?

    private let back: ChromeIconButton?
    private let forward: ChromeIconButton?
    private let reload: ChromeIconButton?
    private var hasButtons: Bool { back != nil }

    public static let backIdentifier = "omnibar.toolbar.back"
    public static let forwardIdentifier = "omnibar.toolbar.forward"
    public static let reloadIdentifier = "omnibar.toolbar.reload"

    public init(suggestionEngine: OmniboxSuggestionEngine, navigation: Bool = false) {
        addressBar = AddressBarView(suggestionEngine: suggestionEngine)
        // The browser toolbar's buttons: Chromium's plain arrows, no tooltip that repeats the name.
        back = navigation ? ChromeIconButton(icon: .browserToolbarBack, label: Strings.back, action: nil, target: nil, toolbar: true, toolTip: false) : nil
        forward = navigation ? ChromeIconButton(icon: .browserToolbarForward, label: Strings.forward, action: nil, target: nil, toolbar: true, toolTip: false) : nil
        reload = navigation ? ChromeIconButton(icon: .browserToolbarReload, label: Strings.reload, action: nil, target: nil, toolbar: true, toolTip: false) : nil
        super.init(frame: .zero)
        // The row is `preferredHeight` tall unless its host sets a height (the popup window's row).
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        // Both layouts below end here: the row follows density and `browser.omnibar.*` sizes live.
        defer {
            density.update { [weak self] in
                guard let self else { return }
                let height = preferredHeight
                if height != shownHeight {
                    shownHeight = height
                    invalidateIntrinsicContentSize()
                }
            }
            density.start()
        }
        // The bar lays itself out with constraints (it turns off autoresizing), so the row places
        // it the same way, as the browser toolbar does.
        addSubview(addressBar)
        let withButtons = navigation
        NSLayoutConstraint.activate([
            density.bind(addressBar.trailingAnchor.constraint(equalTo: trailingAnchor)) { -OmnibarStyle.toolbarInset },
            density.bind(addressBar.topAnchor.constraint(equalTo: topAnchor)) { [weak self] in
                OmnibarStyle.barTop(scale: self?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, withButtons: withButtons)
            },
            density.bind(addressBar.heightAnchor.constraint(equalToConstant: 0)) { OmnibarStyle.barHeight },
        ])
        guard let back, let forward, let reload else {
            density.bind(addressBar.leadingAnchor.constraint(equalTo: leadingAnchor)) { OmnibarStyle.toolbarInset }.isActive = true
            return
        }
        back.setAccessibilityIdentifier(Self.backIdentifier)
        forward.setAccessibilityIdentifier(Self.forwardIdentifier)
        reload.setAccessibilityIdentifier(Self.reloadIdentifier)
        for (button, action) in [(back, #selector(goBack)), (forward, #selector(goForward)), (reload, #selector(reloadPage))] {
            button.target = self
            button.action = action
        }
        // The browser toolbar's navigation group (BrowserChromeView.buildLayout): leading, on the
        // omnibar's vertical center, one bar margin before the field.
        let navigationGroup = NSStackView(views: [back, forward, reload])
        navigationGroup.translatesAutoresizingMaskIntoConstraints = false
        navigationGroup.setHuggingPriority(.required, for: .horizontal)
        addressBar.setContentHuggingPriority(.init(1), for: .horizontal)
        addSubview(navigationGroup)
        navigationGroup.spacing = OmnibarStyle.buttonSpacing
        density.update { navigationGroup.spacing = OmnibarStyle.buttonSpacing }
        NSLayoutConstraint.activate([
            density.bind(navigationGroup.leadingAnchor.constraint(equalTo: leadingAnchor)) { OmnibarStyle.toolbarInset },
            navigationGroup.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),
            density.bind(addressBar.leadingAnchor.constraint(equalTo: navigationGroup.trailingAnchor)) { OmnibarStyle.barMargin },
        ])
        setNavigation(canGoBack: false, canGoForward: false, canReload: false)
    }

    /// Enables Back, Forward and Reload (a row without `navigation` ignores it).
    public func setNavigation(canGoBack: Bool, canGoForward: Bool, canReload: Bool) {
        back?.isEnabled = canGoBack
        forward?.isEnabled = canGoForward
        reload?.isEnabled = canReload
    }

    @objc private func goBack() { onBack?() }
    @objc private func goForward() { onForward?() }
    @objc private func reloadPage() { onReload?() }

    /// Re-applies the metrics when the density changes (`DensityBinding`).
    private let density = DensityBinding()
    /// The height `intrinsicContentSize` last reported.
    private var shownHeight: CGFloat?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The browser toolbar row's height on this window's pixel grid (else the main screen's).
    public var preferredHeight: CGFloat {
        OmnibarStyle.toolbarHeight(scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, withButtons: hasButtons)
    }

    /// The row's height (`preferredHeight`); a density or `browser.omnibar.*` size change
    /// invalidates it, so a host that leaves the height to the row (the Markdown tab) follows live.
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    /// The window's pixel grid snaps the height.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateIntrinsicContentSize()
    }

    nonisolated public override var isFlipped: Bool { true }

    /// A move to a screen with another scale snaps the omnibar's top again.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        density.reapply()
    }

    public override func layout() {
        super.layout()
        addressBar.followLayout()
    }
}
