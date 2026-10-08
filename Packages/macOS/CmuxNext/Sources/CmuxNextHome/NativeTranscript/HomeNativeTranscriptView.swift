public import AppKit
public import CmuxHomeCore
public import CmuxHomeRender
import CmuxNextDesign
import MessagesLabHome

/// The Home transcript (plans/cmux-next/home-mac.md): MessagesLabAppKitNative's
/// own code and motion (`MessagesLabHome`, vendored at the MessagesLab
/// commit in Packages/Shared/CmuxMessagesLab/vendor.tsv),
/// hosted in the pane over the shared HomeStore. The rows, springs, send
/// morph, Liquid Glass field and its render-server field animation, the
/// blurred header and native scrolling are MessagesLab's; this view adds the
/// cmux parts around it: the theme, the first-run panel, focus,
/// availability, and lane 16's attachment intake (the file picker, paste
/// and drop checks, preparing through HomeStore, the notice above the
/// field). Data reaches it only from HomeStore (the single writer); sends
/// and tapbacks leave as HomeIntents. The view owns its conversation's
/// `HomeStoreBinding` (refusals, unanswered ops, attachment fetches, Cancel
/// Upload), so no host can leave those unwired.
public final class HomeNativeTranscriptView: NSView {
    let transcript: MessagesLabHomeView
    let firstRun = HomeFirstRunView()
    let me: ParticipantID
    /// This conversation's part of the store: chained refusal and
    /// unanswered callbacks, attachment bytes, Cancel Upload.
    public let binding: HomeStoreBinding
    /// The notice above the field (an attachment refused, a send refused in
    /// the background, an op that may not have gone through).
    let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var notice: String?
    /// Prepares dropped, pasted and picked files (the data side; the store
    /// by default, a recorder in tests). Nil: the composer takes none.
    public var attachmentPreparer: (any HomeAttachmentPreparing)?
    /// Whether photos and videos keep their location (Settings > Home,
    /// `home.attachments.keepLocation`; false strips it, the default).
    public var keepLocation: () -> Bool = { false }
    /// The chain of attachment preparations, in the order they arrived.
    // task-owner: replaced by the next intake; awaited by attachmentsReady
    var intake: Task<Void, Never>?
    private var stopped = false
    /// False while the owner is unreachable (H17: offline Send is off; the
    /// text stays a draft). The wiring sets it from `HomeStore.connection`.
    public var isSendEnabled = true {
        didSet { transcript.isSendEnabled = isSendEnabled }
    }
    /// A chosen sent-bubble colour (opt in); nil keeps iMessage blue on every theme.
    public var accentOverride: NSColor? { didSet { applyTheme() } }
    /// The first-run panel's open-a-terminal or start-an-agent row was
    /// picked (the host runs the matching registry action).
    public var onFirstRunAction: (HomeFirstRunAction) -> Void = { _ in }
    /// The host is still loading the conversation's first page: the
    /// first-run panel waits, so a Chief conversation with history never
    /// flashes it before its messages arrive (stability rule).
    public var holdsFirstRun = false { didSet { if holdsFirstRun != oldValue { updateFirstRun() } } }
    private var observers: [any NSObjectProtocol] = []

    public init(store: HomeStore, conversation: ConversationID, me: ParticipantID) {
        self.me = me
        transcript = MessagesLabHomeView(store: store, conversation: conversation, me: me, wake: HomeDemandWake())
        // One binding per shown conversation; it opens the conversation on
        // the store now and `stop()` closes exactly that open, once.
        binding = HomeStoreBinding(store: store, conversation: conversation)
        attachmentPreparer = store
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(transcript)
        addSubview(firstRun)
        noticeLabel.isHidden = true
        noticeLabel.font = Typography.caption
        noticeLabel.alignment = .center
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.isSelectable = false
        addSubview(noticeLabel)
        connectAttachments()
        firstRun.isHidden = true
        firstRun.onSuggestion = { [weak self] prompt in
            guard let self else { return }
            self.transcript.setDraft(prompt)
            self.window?.makeFirstResponder(self.transcript.primaryInput)
        }
        firstRun.onAction = { [weak self] action in self?.onFirstRunAction(action) }
        transcript.onSummaryChange = { [weak self] _ in self?.updateFirstRun() }
        transcript.onRowsChange = { [weak self] in self?.updateFirstRun() }
        followTextSize()
        applyTheme()
        updateFirstRun()
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Stops forwarding (the conversation closed). Once.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        intake?.cancel()
        transcript.stop()
        binding.stop()
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// A click on the header's name pill (the Chief's settings sidebar).
    public var onNamePill: () -> Void {
        get { transcript.onNamePill }
        set { transcript.onNamePill = newValue }
    }

    /// The header avatar's text; nil shows the conversation's initials.
    public var avatarText: String? {
        get { transcript.avatarText }
        set { transcript.avatarText = newValue }
    }

    /// The name pill's VoiceOver help.
    public func setNamePillHelp(_ help: String) { transcript.setNamePillHelp(help) }

    /// The primary input (spec/app-screens.md section 3): the message box's
    /// text view. Hosts focus this view, not the transcript.
    public var primaryInput: NSView { transcript.primaryInput }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(primaryInput) ?? false
    }

    /// The live interface scale applies to the native first-run chrome. The
    /// MessagesLab transcript owns its own text and field metrics.
    private func followTextSize() {
        withObservationTracking {
            applyTextScale(Typography.userScale)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followTextSize() }
        }
    }

    func applyTextScale(_ scale: CGFloat) {
        firstRun.applyScale(scale)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        // Showing the tab again re-attaches the same views: nothing to do
        // unless the size changed (no layout, bitmap or backdrop rebuild).
        guard transcript.frame != bounds else { layoutNotice(); return }
        transcript.frame = bounds
        transcript.layoutSubtreeIfNeeded()
        let top = transcript.headerHeight
        firstRun.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, transcript.fieldTop - top))
        layoutNotice()
    }

    /// Above the field, inset like it; MessagesLab's field keeps its geometry.
    func layoutNotice() {
        guard notice != nil else { return }
        let width = max(0, bounds.width - 32)
        noticeLabel.preferredMaxLayoutWidth = width
        let height = ceil(noticeLabel.intrinsicContentSize.height)
        noticeLabel.frame = CGRect(x: 16, y: transcript.fieldTop - height - 8, width: width, height: height)
    }

    /// A notice about the conversation itself (Home's merge notice): a row of
    /// the transcript, under the newest message; nil removes it.
    public func showConversationNotice(_ text: String?) {
        guard transcript.notice != text else { return }
        transcript.notice = text
        if let text {
            NSAccessibility.post(element: transcript, notification: .announcementRequested, userInfo: [.announcement: text])
        }
    }

    /// Shows (or with nil clears) the notice; VoiceOver hears it.
    public func showNotice(_ text: String?) {
        guard text != notice else { return }
        notice = text
        noticeLabel.stringValue = text ?? ""
        noticeLabel.isHidden = text == nil
        noticeLabel.setAccessibilityLabel(text)
        if let text {
            NSAccessibility.post(element: noticeLabel, notification: .announcementRequested, userInfo: [.announcement: text])
        }
        layoutNotice()
    }

    /// The first-run rows' shortcuts and the tab hint's keys, as the
    /// registry shows them; nil hides one.
    public func setFirstRunShortcuts(terminal: String?, agent: String?, tabs: String?) {
        firstRun.setShortcuts(terminal: terminal, agent: agent, tabs: tabs)
    }

    /// The first-run panel shows only in an empty Chief conversation.
    private func updateFirstRun() {
        firstRun.isHidden = holdsFirstRun || !(transcript.isEmpty && transcript.conversationSummary?.kind(me: me) == .chief)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guard let window else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowStateChanged() }
            })
        }
        windowStateChanged()
        // A theme change while the tab was hidden (equal palettes return early).
        applyTheme()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func windowStateChanged() {
        transcript.isVisibleToUser = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
    }

    /// The theme's palettes (key and non-key window) for the MessagesLab
    /// Fixture colours, and the first-run panel's colours.
    private func applyTheme() {
        let accent = accentOverride
        let active = performWithTheme { HomeThemePalette.resolveInScope(active: true, accentOverride: accent) }
        let inactive = performWithTheme { HomeThemePalette.resolveInScope(active: false, accentOverride: accent) }
        let measured = performWithTheme { HomeThemePalette.usesMessagesBlueInScope(accentOverride: accent) }
        transcript.applyTheme(active: active, inactive: inactive, measuredAccent: measured)
        // The header's band: a light fade of the window background, shown only
        // near the top; the design system's fades, none under Reduce Motion.
        let (fade, maxAlpha) = performWithTheme { (Palette.surfaceBackground.withAlphaComponent(1), Palette.legibilityScrimOpacity) }
        transcript.setHeaderFade(color: fade, maxAlpha: maxAlpha) { shown in
            Motion.reduceMotion ? 0 : Motion.duration(shown ? .fadeIn : .fadeOut)
        }
        performWithTheme {
            firstRun.applyColors(primary: Palette.textPrimary, secondary: Palette.textSecondary, tertiary: Palette.textTertiary,
                                 fill: Palette.elevatedBackground, hover: Palette.hoverFill, border: Palette.separator)
            noticeLabel.textColor = Palette.textSecondary
        }
    }
}
