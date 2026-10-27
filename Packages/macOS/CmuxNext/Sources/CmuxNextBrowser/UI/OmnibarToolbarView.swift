public import AppKit
import CmuxNextDesign
public import CmuxNextWakeups

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

    /// `mainWork` is the app's one main-thread scheduler (the bar's setting follows apply on it).
    public init(suggestionEngine: OmniboxSuggestionEngine, navigation: Bool = false, mainWork: MainWorkScheduler) {
        addressBar = AddressBarView(suggestionEngine: suggestionEngine, mainWork: mainWork)
        // The browser toolbar's buttons: Chromium's plain arrows, no tooltip that repeats the name.
        back = navigation ? ChromeIconButton(icon: .browserToolbarBack, label: Strings.back, action: nil, target: nil, toolbar: true, toolTip: false) : nil
        forward = navigation ? ChromeIconButton(icon: .browserToolbarForward, label: Strings.forward, action: nil, target: nil, toolbar: true, toolTip: false) : nil
        reload = navigation ? ChromeIconButton(icon: .browserToolbarReload, label: Strings.reload, action: nil, target: nil, toolbar: true, toolTip: false) : nil
        super.init(frame: .zero)
        addSubview(addressBar)
        density.update { [weak self] in self?.applyMetrics() }
        density.start(in: self)
        guard let back, let forward, let reload else { return }
        back.setAccessibilityIdentifier(Self.backIdentifier)
        forward.setAccessibilityIdentifier(Self.forwardIdentifier)
        reload.setAccessibilityIdentifier(Self.reloadIdentifier)
        for (button, action) in [(back, #selector(goBack)), (forward, #selector(goForward)), (reload, #selector(reloadPage))] {
            button.target = self
            button.action = action
            addSubview(button)
        }
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
    /// The row's token sizes (`applyMetrics`).
    private var metrics: ToolbarRowLayout.Metrics? {
        didSet { if metrics != oldValue { needsLayout = true } }
    }

    /// The browser toolbar's sizes: the bar at its top padding and side insets, the buttons at
    /// the browser's place and size, one bar margin before the field.
    private func applyMetrics() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metrics = ToolbarRowLayout.Metrics(
            inset: OmnibarStyle.toolbarInset, barMargin: OmnibarStyle.barMargin, buttonSpacing: OmnibarStyle.buttonSpacing,
            buttonSize: OmnibarStyle.buttonSize, barTop: OmnibarStyle.barTop(scale: scale, withButtons: hasButtons),
            barHeight: OmnibarStyle.barHeight
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The browser toolbar row's height on this window's pixel grid (else the main screen's).
    public var preferredHeight: CGFloat {
        OmnibarStyle.toolbarHeight(scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, withButtons: hasButtons)
    }

    nonisolated public override var isFlipped: Bool { true }

    /// A move to a screen with another scale snaps the omnibar's top again.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        density.reapply()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    /// The row's frames for its size now (the browser toolbar's `ToolbarRowLayout`, no trailing group).
    var rowLayout: ToolbarRowLayout? {
        guard let metrics else { return nil }
        return ToolbarRowLayout(ToolbarRowLayout.Input(
            size: bounds.size, position: .top, navigationButtons: navigationButtons.count, trailing: nil, metrics: metrics
        ))
    }

    private var navigationButtons: [ChromeIconButton] { [back, forward, reload].compactMap { $0 }.filter { !$0.isHidden } }

    public override func layout() {
        super.layout()
        if let row = rowLayout {
            let mapping = chromeFrameMapping
            for (button, rect) in zip(navigationButtons, row.navigation) { button.setChromeFrame(mapping.map(rect)) }
            addressBar.setChromeFrame(mapping.map(row.address))
        }
        addressBar.followLayout()
    }
}
