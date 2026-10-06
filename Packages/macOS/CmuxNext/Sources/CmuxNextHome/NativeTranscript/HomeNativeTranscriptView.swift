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
    /// Prepares dropped, pasted and picked files (the data side). Nil:
    /// the composer takes no attachments and shows no attach button.
    public var attachmentPreparer: (any HomeAttachmentPreparing)? {
        didSet { field.attachEnabled = attachmentPreparer != nil }
    }
    /// The chain of attachment preparations, in the order they arrived.
    // task-owner: replaced by the next intake; awaited by attachmentsReady
    var intake: Task<Void, Never>?
    /// The drafts of the last send by content hash: a send the owner
    /// refuses before logging it gets them back (`onRestoreAttachments`).
    var sentDrafts: [String: HomeDraftAttachment] = [:]
    /// Cancels my pending send (`HomeStoreBinding.cancelSend`); the menu
    /// offers it only while `HomeController.cancellableSend` is true.
    public var onCancelSend: (IdempotencyKey) -> Bool = { _ in false }
    /// The first-run panel's open-a-terminal or start-an-agent row was
    /// picked (the host runs the matching registry action).
    public var onFirstRunAction: (HomeFirstRunAction) -> Void = { _ in }
    /// The host is still loading the conversation's first page: the
    /// first-run panel waits, so a Chief conversation with history never
    /// flashes it before its messages arrive (stability rule).
    public var holdsFirstRun = false { didSet { if holdsFirstRun != oldValue { updateFirstRun() } } }
    private var observers: [any NSObjectProtocol] = []

    static let fieldInset: CGFloat = 16
    static let fieldBottom: CGFloat = 14
    /// A wide window centres the field at a reading width instead of
    /// stretching one bar across the page.
    static let fieldMaxWidth: CGFloat = 760

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
        addSubview(firstRun)
        firstRun.isHidden = true
        firstRun.onSuggestion = { [weak self] prompt in
            guard let self else { return }
            self.field.text = prompt
            self.window?.makeFirstResponder(self.field.textView)
            self.needsLayout = true
        }
        firstRun.onAction = { [weak self] action in self?.onFirstRunAction(action) }
        addSubview(field)
        addSubview(header)
        controller.topInset = header.scaledHeight
        controller.onSummaryChange = { [weak self] summary in
            guard let self else { return }
            self.header.show(summary, me: self.controller.me)
            self.updateFirstRun()
        }
        controller.onScrollGeometryChange = { [weak self] g in self?.scroll.apply(g) }
        controller.onAccessibilityChange = { [weak self] in self?.rowHost.accessibilityChanged() }
        controller.onRowsChange = { [weak self] in
            self?.rowHost.rowsChanged()
            self?.updateFirstRun()
        }
        controller.onRestoreDraft = { [weak self] text in
            guard let self, self.field.text.isEmpty else { return }
            self.field.text = text
        }
        field.onSend = { [weak self] in self?.sendDraft() }
        field.onAttach = { [weak self] in self?.pickFiles() }
        field.onAttachmentPasteboard = { [weak self] board in self?.handlePaste(board) ?? false }
        rowHost.onVideoClick = { [weak self] hit in
            guard let self, self.controller.toggleVideo(hit) else { return false }
            self.rowHost.accessibilityChanged()
            return true
        }
        rowHost.onCancelSend = { [weak self] key in self?.onCancelSend(key) ?? false }
        controller.onRestoreAttachments = { [weak self] refs in
            guard let self else { return }
            for ref in refs { if let draft = self.sentDrafts[ref.hash] { self.field.addDraft(draft) } }
        }
        registerForDraggedTypes(HomeAttachmentIntake.dragTypes)
        rowHost.onEmptyClick = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field.textView)
        }
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
        firstRun.applyScale(scale)
        header.applyScale(scale)
        controller.topInset = header.scaledHeight
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// The primary input (spec/app-screens.md section 3): the message box's
    /// text view. Hosts focus this view, not the transcript.
    public var primaryInput: NSView { field.textView }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(field.textView) ?? false
    }

    /// The field's frame in viewport points (top-left origin).
    var fieldFrame: CGRect {
        let h = field.preferredHeight
        let width = max(60, min(Self.fieldMaxWidth, bounds.width - 2 * Self.fieldInset))
        return CGRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - Self.fieldBottom - h, width: width, height: h)
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
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: header.scaledHeight)
        layoutField(send: false)
        let top = header.scaledHeight
        firstRun.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, fieldFrame.minY - top))
        updateFirstRun()
        scroll.apply(controller.scrollGeometry)
    }

    /// The first-run rows' shortcuts and the tab hint's keys, as the
    /// registry shows them; nil hides one.
    public func setFirstRunShortcuts(terminal: String?, agent: String?, tabs: String?) {
        firstRun.setShortcuts(terminal: terminal, agent: agent, tabs: tabs)
    }

    /// The first-run panel shows only in an empty Chief conversation.
    private func updateFirstRun() {
        let me = controller.me
        firstRun.isHidden = holdsFirstRun || !(controller.isEmpty && controller.conversationSummary?.kind(me: me) == .chief)
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

    /// Sends the text and the draft attachments as one message; each
    /// attachment flies from its tray chip into its bubble.
    func sendDraft() {
        guard isSendEnabled else { return }
        let frame = fieldFrame
        let drafts = field.draftAttachments
        let outgoing = drafts.map { draft in
            HomeOutgoingAttachment(ref: draft.ref, files: draft.prepared.files,
                                   origin: field.tray.chipFrame(draft.ref.hash).map { field.tray.convert($0, to: self) },
                                   preview: draft.thumbnail)
        }
        guard controller.sendHosted(text: field.text, attachments: outgoing, from: frame) != nil else { return }
        sentDrafts = Dictionary(drafts.map { ($0.ref.hash, $0) }, uniquingKeysWith: { a, _ in a })
        field.text = ""
        field.clearDrafts()
        field.showNotice(nil)
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
        performWithTheme {
            // The header takes the transcript's own fill, so the two read as
            // one page; over a see-through fill (window backdrop art) it fades
            // from the opaque page colour so no bar edge sits on the art.
            let home = Palette.fill(for: .home, default: Palette.paneFill)
            let seeThrough = home.alphaComponent < 1
            header.applyColors(disc: Palette.elevatedBackground, text: Palette.textPrimary,
                               page: seeThrough ? Palette.pageBackground : home, seeThrough: seeThrough,
                               accent: Palette.highlight)
            firstRun.applyColors(primary: Palette.textPrimary, secondary: Palette.textSecondary, tertiary: Palette.textTertiary,
                                 fill: Palette.elevatedBackground, hover: Palette.hoverFill, border: Palette.separator)
            field.applyColors(fill: Palette.elevatedBackground, border: Palette.separator,
                              text: Palette.textPrimary, secondary: Palette.textTertiary)
        }
    }
}
