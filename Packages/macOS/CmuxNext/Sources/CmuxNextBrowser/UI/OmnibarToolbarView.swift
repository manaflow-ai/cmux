public import AppKit
import CmuxNextDesign

/// The browser toolbar's omnibar row for a surface that is not a browser pane: a popup window and
/// the Markdown tab. The row is the browser toolbar's own page (`BrowserToolbarWebView`, one
/// implementation with the browser tab: field, suggestions, keys), at the toolbar's height. The
/// cursor follows the browser toolbar's rules (`ArrowCursorView`, `OmnibarPointer`).
///
/// With `navigation` the page also draws Back, Forward and Reload at the browser's place and size,
/// for a surface that navigates like a page (the Markdown tab). The owner says what they do
/// (``onBack``, ``onForward``, ``onReload``) and when they are enabled
/// (``setNavigation(canGoBack:canGoForward:canReload:)``).
public final class OmnibarToolbarView: ArrowCursorView {
    public let addressBar: BrowserToolbarWebView
    /// What Back, Forward and Reload do; each runs only while its button is enabled.
    public var onBack: (() -> Void)?
    public var onForward: (() -> Void)?
    public var onReload: (() -> Void)?

    private let hasButtons: Bool
    private var canReload = false
    /// Re-applies the metrics when the density changes (`DensityBinding`).
    private let density = DensityBinding()
    /// The height `intrinsicContentSize` last reported.
    private var shownHeight: CGFloat?

    public init(suggestionEngine: OmniboxSuggestionEngine, navigation: Bool = false) {
        addressBar = BrowserToolbarWebView(suggestionEngine: suggestionEngine, showsButtons: navigation)
        hasButtons = navigation
        super.init(frame: .zero)
        // Nothing to reload until a host sets the row's navigation (an empty Markdown tab never does).
        addressBar.navigation = ToolbarNavigation(canReload: false)
        // The row is `preferredHeight` tall unless its host sets a height (the popup window's row).
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        addSubview(addressBar)
        NSLayoutConstraint.activate([
            addressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            addressBar.topAnchor.constraint(equalTo: topAnchor),
            addressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addressBar.onCommand = { [weak self] command in self?.perform(command) }
        density.update { [weak self] in
            guard let self else { return }
            let height = preferredHeight
            if height != shownHeight {
                shownHeight = height
                invalidateIntrinsicContentSize()
            }
            addressBar.setNeedsPush()
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Enables Back, Forward and Reload (a row without `navigation` ignores it).
    public func setNavigation(canGoBack: Bool, canGoForward: Bool, canReload: Bool) {
        self.canReload = canReload
        addressBar.navigation = ToolbarNavigation(canGoBack: canGoBack, canGoForward: canGoForward, loading: false, canReload: canReload)
    }

    private func perform(_ command: BrowserToolbarPageCommand) {
        switch command {
        case .goBack: if addressBar.navigation.canGoBack { onBack?() }
        case .goForward: if addressBar.navigation.canGoForward { onForward?() }
        case .reload: if canReload { onReload?() }
        default: break
        }
    }

    /// The browser toolbar row's height on this window's pixel grid (else the main screen's).
    public var preferredHeight: CGFloat {
        ToolbarRowMetrics.toolbarHeight(scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, withButtons: hasButtons)
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

    /// The row resized, or moved in its page tab (a bottom row when the pane's height changes): an
    /// open suggestion card follows it.
    public override func layout() {
        super.layout()
        addressBar.followLayout()
    }

    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        addressBar.followLayout()
    }
}
