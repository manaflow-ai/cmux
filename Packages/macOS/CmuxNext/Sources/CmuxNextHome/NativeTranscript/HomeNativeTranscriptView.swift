public import AppKit
public import CmuxHomeCore
public import CmuxHomeRender
import CmuxNextDesign
import Observation

/// The Home transcript on the shared render core with native AppKit parts
/// (plans/cmux-next/home-mac.md, mac-home-rendering.md option B): the rows,
/// their springs and the send morph come from `CmuxHomeRender`; scrolling is
/// an NSScrollView, the compose field a Liquid Glass NSTextView. Data comes
/// in only through `controller.update` (or `HomeStoreBinding`); intents
/// leave through `controller.onIntent`.
public final class HomeNativeTranscriptView: NSView {
    public let controller: HomeController
    let scroll = HomeTranscriptScrollView()
    let rowHost = HomeRowHostView()
    let field = HomeFieldView()
    let header = HomeGlassHeaderView()
    let firstRun = HomeFirstRunView()
    /// False while the owner is unreachable (H17: offline Send is off; the
    /// text stays a draft). The wiring sets it from `HomeStore.connection`.
    public var isSendEnabled = true {
        didSet { rowHost.reactionsEnabled = isSendEnabled }
    }
    /// A user-chosen sent-bubble colour; nil follows the theme.
    public var accentOverride: NSColor? { didSet { applyTheme() } }
    private var observers: [any NSObjectProtocol] = []

    static let fieldInset: CGFloat = 16
    static let fieldBottom: CGFloat = 10.75

    public init(conversation: ConversationID, me: ParticipantID) {
        let palette = ThemeScope.app.perform { HomeThemePalette.resolveInScope(active: true) }
        controller = HomeController(conversation: conversation, me: me, palette: palette, deadline: HomeDemandDeadline())
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(scroll)
        scroll.rowHost.addSubview(rowHost)
        rowHost.controller = controller
        rowHost.layer?.addSublayer(controller.rootLayer)
        scroll.controller = controller
        addSubview(field)
        addSubview(header)
        controller.topInset = HomeGlassHeaderView.height
        controller.onSummaryChange = { [weak self] summary in
            guard let self else { return }
            self.header.show(summary, me: self.controller.me)
        }
        controller.onScrollGeometryChange = { [weak self] g in self?.scroll.apply(g) }
        controller.onAccessibilityChange = { [weak self] in self?.rowHost.accessibilityChanged() }
        controller.onRowsChange = { [weak self] in self?.rowHost.rowsChanged() }
        controller.onRestoreDraft = { [weak self] text in
            guard let self, self.field.text.isEmpty else { return }
            self.field.text = text
        }
        field.onSend = { [weak self] in self?.send() }
        field.onHeightChange = { [weak self] in self?.needsLayout = true }
        followTextSize()
    }

    /// The Mac's text size (Settings > Interface Size, the palette's
    /// Increase, Decrease and Reset Interface Size) scales the transcript and
    /// the field, live: `DesignSettings` is observed, not polled.
    private func followTextSize() {
        withObservationTracking {
            applyTextScale(Typography.userScale)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followTextSize() }
        }
    }

    func applyTextScale(_ scale: CGFloat) {
        controller.textScale = scale
        field.scale = controller.textScale
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(field.textView) ?? false
    }

    /// The field's frame in viewport points (top-left origin).
    var fieldFrame: CGRect {
        let h = field.preferredHeight
        return CGRect(x: Self.fieldInset, y: bounds.height - Self.fieldBottom - h,
                      width: max(60, bounds.width - 2 * Self.fieldInset), height: h)
    }

    public override func layout() {
        super.layout()
        scroll.frame = bounds
        rowHost.frame = CGRect(origin: .zero, size: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controller.rootLayer.frame = rowHost.bounds
        CATransaction.commit()
        controller.resize(to: bounds.size)
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: HomeGlassHeaderView.height)
        layoutField(send: false)
        scroll.apply(controller.scrollGeometry)
    }

    private func layoutField(send: Bool) {
        let f = fieldFrame
        guard field.frame != f || send else { return }
        let old = field.frame
        if old.height != f.height, old.height > 0, window != nil,
           let keyframes = controller.fieldKeyframes(from: old, to: f, send: send) {
            HomeFieldSpring.animate(field, to: f, keyframes: keyframes)
        } else {
            field.animations = [:]
            field.frame = f
        }
        controller.setHostedField(f, send: send)
    }

    private func send() {
        guard isSendEnabled else { return }
        let frame = fieldFrame
        guard controller.sendHosted(text: field.text, from: frame) != nil else { return }
        field.text = ""
        layoutField(send: true)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guard let window else { return }
        controller.contentsScale = window.backingScaleFactor
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowStateChanged() }
            })
        }
        windowStateChanged()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller.contentsScale = window?.backingScaleFactor ?? 2
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func windowStateChanged() {
        controller.isVisibleToUser = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
        applyTheme()
    }

    private func applyTheme() {
        let active = window?.isKeyWindow ?? true
        let accent = accentOverride
        controller.palette = performWithTheme { HomeThemePalette.resolveInScope(active: active, accentOverride: accent) }
        performWithTheme { header.applyColors(disc: Palette.elevatedBackground, text: Palette.textPrimary, page: Palette.pageBackground) }
    }
}
