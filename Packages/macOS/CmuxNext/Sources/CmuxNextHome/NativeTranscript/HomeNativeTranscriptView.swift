public import AppKit
public import CmuxHomeCore
public import CmuxHomeRender
public import CmuxNextDesign
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
    let noticeLabel = ChromeLabel(wrappingLabelWithString: "")
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
    /// The composer rect toasts last moved clear of (posted on change).
    private var lastToastAvoidance = NSRect.zero
    /// False while the owner is unreachable (H17: offline Send is off; the
    /// text stays a draft). The wiring sets it from `HomeStore.connection`.
    public var isSendEnabled = true {
        didSet { transcript.isSendEnabled = isSendEnabled }
    }
    /// The Chief works: the compose bar offers Stop (the button, Esc, Cmd-.).
    public var isWorking = false {
        didSet { if isWorking != oldValue { transcript.isWorking = isWorking } }
    }
    /// A click on a Chief subagent's link in agent text (the host's `link.open`).
    public var onAppLink: ((URL) -> Void)? {
        get { transcript.onAppLink }
        set { transcript.onAppLink = newValue }
    }
    /// A click on any other link in the transcript (`otherTarget`: Shift-Command held).
    public var onOpenLink: (_ url: URL, _ otherTarget: Bool) -> Void {
        get { transcript.onOpenLink }
        set { transcript.onOpenLink = newValue }
    }
    /// The host's shared stop action.
    public var onStop: () -> Void = {} {
        didSet { transcript.onStop = { [weak self] in self?.onStop() } }
    }
    /// A chosen sent-bubble colour (opt in); nil keeps iMessage blue on every theme.
    public var accentOverride: NSColor? { didSet { applyTheme() } }
    /// The first-run panel's open-a-terminal or start-an-agent row was
    /// picked (the host runs the matching registry action).
    public var onFirstRunAction: (HomeFirstRunAction) -> Void = { _ in }
    /// An agent row of the first-run panel was picked: the host opens that
    /// tab (its daemon tab id).
    public var onFirstRunAgent: (String) -> Void = { _ in }
    /// The host is still loading the conversation's first page: the
    /// first-run panel waits, so a Chief conversation with history never
    /// flashes it before its messages arrive (stability rule).
    public var holdsFirstRun = false { didSet { if holdsFirstRun != oldValue { updateFirstRun() } } }
    /// Automation (DEBUG socket): the transcript sits this far from this view's origin, with no size change
    /// (a pane on a fraction of a point; MessagesLab b6760b6's typing snap). Zero in the product.
    public var debugTranscriptOffset = CGPoint.zero { didSet { needsLayout = true } }
    /// Automation (DEBUG socket): the transcript is this much narrower than this view (a pane's width
    /// change, as a divider drag or a live resize makes it). Zero in the product.
    public var debugTranscriptWidthTrim: CGFloat = 0 { didSet { needsLayout = true } }
    private var observers: [any NSObjectProtocol] = []
    /// The window's typing hold for the compose field's cursor rects (HomeCursorRectHold).
    private var cursorHold: HomeCursorRectHold?

    public init(store: HomeStore, conversation: ConversationID, me: ParticipantID) {
        HomeReduceMotion.install()
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
        firstRun.onAction = { [weak self] action in self?.onFirstRunAction(action) }
        firstRun.onAgent = { [weak self] id in self?.onFirstRunAgent(id) }
        transcript.onSummaryChange = { [weak self] _ in self?.updateFirstRun() }
        transcript.onRowsChange = { [weak self] in self?.updateFirstRun() }
        followTextSize()
        applyTheme()
        updateFirstRun()
    }

    required init?(coder: NSCoder) { nil }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }

    /// Stops forwarding (the conversation closed). Once.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        intake?.cancel()
        transcript.stop()
        binding.stop()
    }

    nonisolated public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    #if DEBUG
    /// The first-run panel is on screen (capture scenes settle on it).
    public var debugFirstRunShown: Bool { !firstRun.isHiddenOrHasHiddenAncestor && firstRun.window != nil }
    /// The first-run panel's listed agents, most urgent first.
    public var debugFirstRunAgents: [HomeDebugAgentRow] { firstRun.debugAgents }
    /// Clicks the panel's agent row `index` (`HomeFirstRunView.debugClickAgent`).
    public func debugClickFirstRunAgent(_ index: Int, pointer: Bool) -> String? { firstRun.debugClickAgent(index, pointer: pointer) }
    #endif

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

    /// The header avatar's picture, over its text; nil shows the text.
    public var avatarPicture: NSImage? {
        get { transcript.avatarPicture }
        set { transcript.avatarPicture = newValue }
    }

    /// The name pill's VoiceOver help.
    public func setNamePillHelp(_ help: String) { transcript.setNamePillHelp(help) }

    /// The primary input (spec/app-screens.md section 3): the message box's
    /// text view. Hosts focus this view, not the transcript.
    public var primaryInput: NSView { transcript.primaryInput }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(primaryInput) ?? false
    }

    /// Whether Home getting focus should move the keyboard from `responder`
    /// to ``primaryInput``: yes, unless a text view or field has it, the
    /// transcript holds or makes a text selection, or the person moves
    /// through the first-run panel's rows with the keyboard.
    /// - Parameter responder: The window's first responder now.
    /// - Returns: True when the host should focus ``primaryInput``.
    public func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, view.isDescendant(of: firstRun), !firstRun.isHiddenOrHasHiddenAncestor {
            return false
        }
        return transcript.primaryInputShouldTakeKeyboard(from: responder)
    }

    /// Cmd+V from the first-run panel (the transcript's own pane handles it
    /// below this view): the message box takes the keyboard and the paste.
    @objc public func paste(_ sender: Any?) { transcript.pasteIntoPrimaryInput(sender) }

    /// Whether ``paste(_:)`` has text, files or pictures for the message box.
    public var canPasteIntoPrimaryInput: Bool { transcript.canPasteIntoPrimaryInput }

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
        // Showing the tab again re-attaches the same views: the transcript is
        // laid out only when the size changed (no bitmap or backdrop rebuild).
        // A size change lays the transcript out; a move only (debugTranscriptOffset) keeps its size.
        // debugTranscriptWidthTrim narrows it (automation: a pane width change).
        var place = bounds.offsetBy(dx: debugTranscriptOffset.x, dy: debugTranscriptOffset.y)
        place.size.width = max(0, place.width - debugTranscriptWidthTrim)
        if transcript.frame != place {
            let resized = transcript.frame.size != place.size
            transcript.frame = place
            if resized { transcript.layoutSubtreeIfNeeded() }
        }
        // Every pass: the field can grow (a multi-line draft) without a size
        // change, and the first-run panel fits its agent rows above it.
        let top = transcript.headerHeight
        let panel = CGRect(x: 0, y: top, width: bounds.width, height: max(0, transcript.fieldTop - top))
        if firstRun.frame != panel { firstRun.frame = panel }
        layoutNotice()
    }

    /// Above the field, inset like it; MessagesLab's field keeps its geometry.
    func layoutNotice() {
        guard notice != nil else { return }
        let width = max(0, bounds.width - 32)
        noticeLabel.preferredMaxLayoutWidth = width
        let height = ceil(noticeLabel.intrinsicContentSize.height)
        noticeLabel.frame = CGRect(x: 16, y: transcript.fieldTop - height - 8, width: width, height: height)
        let avoided = toastAvoidanceRect
        if avoided != lastToastAvoidance {
            lastToastAvoidance = avoided
            NotificationCenter.default.post(name: .cmuxToastAvoidanceDidChange, object: self)
        }
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

    /// The user's agents for the first-run panel's glance (the host maps
    /// them from the tab status the strip and the sidebar draw); empty lists
    /// none.
    public func setFirstRunAgents(_ agents: [HomeAgentGlance]) {
        firstRun.setAgents(agents)
    }

    /// The first-run panel shows only in an empty Chief conversation.
    private func updateFirstRun() {
        firstRun.isHidden = holdsFirstRun || !(transcript.isEmpty && transcript.conversationSummary?.kind(me: me) == .chief)
    }

    /// The typing hold gives back what it holds while the views are still in the old window.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        cursorHold?.remove(self)
        cursorHold = nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        cursorHold = window.flatMap(HomeCursorRectHold.hold(for:))
        cursorHold?.add(self)
        guard let window else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowStateChanged() } // main-proof: observer on queue: .main
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

    /// The header band's fade in or out, in seconds. Reduce Motion keeps it, at the crossfade length
    /// (motion.md rule 7): turned off there, the band appeared and left in one frame.
    static func headerFadeDuration(shown: Bool) -> TimeInterval {
        Motion.duration(shown ? .fadeIn : .fadeOut)
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
        // near the top; the design system's fades.
        let (fade, maxAlpha) = performWithTheme { (Palette.surfaceBackground.withAlphaComponent(1), Palette.legibilityScrimOpacity) }
        transcript.setHeaderPillBacking(performWithTheme { Palette.capsuleScrim })
        transcript.setHeaderFade(color: fade, maxAlpha: maxAlpha) { shown in Self.headerFadeDuration(shown: shown) }
        performWithTheme {
            firstRun.applyColors(primary: Palette.textPrimary, tertiary: Palette.textTertiary, fill: Palette.elevatedBackground,
                                 hover: Palette.hoverFill, border: Palette.separator, attention: Palette.attention,
                                 danger: Palette.danger, done: Palette.highlight)
            noticeLabel.textColor = Palette.textSecondary
        }
    }
}

/// Toasts stay clear of the composer and its buttons (the area below the
/// field's top edge).
extension HomeNativeTranscriptView: CmuxToastAvoiding {
    public var toastAvoidanceRect: NSRect {
        let top = transcript.fieldTop
        return NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }
}

