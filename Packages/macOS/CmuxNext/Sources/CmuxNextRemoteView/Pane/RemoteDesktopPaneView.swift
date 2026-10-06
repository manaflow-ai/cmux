public import AppKit
import CmuxNextDesign

// Development builds only: the pane is not exposed in Release until the
// overlay link token authenticates hello claims (RemoteViewAvailability).
#if DEBUG
/// The remote desktop pane: video, input surface and chrome variant A.
/// AppKit, manual layout. It renders a `RemotePaneState` and reports the
/// viewer's choices through closures; `RemoteDesktopPane` owns the state.
public final class RemoteDesktopPaneView: NSView {
    let video = RemoteVideoView()
    let capture = RemoteInputCaptureView()
    let toolbar = RemoteHoverToolbar()
    let banner = RemoteLatencyBanner()
    let card = RemoteStateCard()
    private var colors = RemotePaneColors()
    private var state: RemotePaneState?
    private var settings = RemoteDesktopSettings()
    private var shownOverlay: RemotePaneOverlay?
    private var isHovering = false

    static let toolbarInset: CGFloat = 8

    public override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for view in [video, capture, toolbar, banner, card] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        toolbar.alphaValue = 0
        toolbar.isHidden = true
        banner.isHidden = true
        card.isHidden = true
        capture.geometry = { [weak self] in self?.video.geometry }
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that takes keyboard focus for the pane.
    public var focusView: NSView { capture }

    func render(state: RemotePaneState, settings: RemoteDesktopSettings) {
        self.state = state
        self.settings = settings
        capture.controller.settings = settings
        capture.controlMode = state.effectiveMode == .control
        video.showsRemoteCursor = state.effectiveMode == .view
        toolbar.update(state: state, settings: settings, colors: colors)
        banner.isHidden = !state.showsLatencyBanner
        if state.showsLatencyBanner { banner.update(state: state, colors: colors) }
        if state.overlay != shownOverlay || state.overlay == nil {
            shownOverlay = state.overlay
            card.isHidden = state.overlay == nil
            if let overlay = state.overlay { card.configure(overlay: overlay, host: state.hostName, colors: colors) }
        }
        setAccessibilityLabel(RemoteViewStrings.accessibilityPane(state.hostName))
        updateToolbarVisibility(animated: true)
        needsLayout = true
    }

    // MARK: Theme

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
    }

    private func refreshColors() {
        let next = performWithTheme { RemotePaneColors.resolved() }
        guard next != colors else { return }
        colors = next
        video.setBackground(next.background)
        if let state {
            shownOverlay = nil
            render(state: state, settings: settings)
        }
    }

    // MARK: Hover chrome

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateToolbarVisibility(animated: true)
    }

    public override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateToolbarVisibility(animated: true)
    }

    private func updateToolbarVisibility(animated: Bool) {
        let visible = isHovering || (state?.pinsToolbar ?? true)
        let target: CGFloat = visible ? 1 : 0
        guard toolbar.alphaValue != target || toolbar.isHidden == visible else { return }
        // A transparent toolbar must not take clicks meant for the host.
        if visible { toolbar.isHidden = false }
        guard animated else {
            toolbar.alphaValue = target
            toolbar.isHidden = !visible
            return
        }
        Motion.animate(visible ? .fadeIn : .fadeOut, in: self, { toolbar.animator().alphaValue = target }, completion: { [weak self] in
            guard let self, !self.isHovering, self.state?.pinsToolbar == false else { return }
            self.toolbar.isHidden = true
        })
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        video.frame = bounds
        capture.frame = bounds
        let inset = Self.toolbarInset
        let toolbarWidth = min(toolbar.fittingWidth, bounds.width - inset * 2)
        toolbar.frame = CGRect(
            x: ((bounds.width - toolbarWidth) / 2).rounded(), y: inset,
            width: max(toolbarWidth, 0), height: RemoteHoverToolbar.height)
        let bannerSize = banner.fittingContentSize
        let bannerWidth = min(bannerSize.width, bounds.width - inset * 2)
        banner.frame = CGRect(
            x: ((bounds.width - bannerWidth) / 2).rounded(), y: toolbar.frame.maxY + inset,
            width: max(bannerWidth, 0), height: bannerSize.height)
        let cardSize = card.fittingContentSize
        let cardWidth = min(max(cardSize.width, 300), bounds.width - inset * 2)
        card.frame = CGRect(
            x: ((bounds.width - cardWidth) / 2).rounded(), y: ((bounds.height - cardSize.height) / 2).rounded(),
            width: max(cardWidth, 0), height: cardSize.height)
    }
}
#endif
