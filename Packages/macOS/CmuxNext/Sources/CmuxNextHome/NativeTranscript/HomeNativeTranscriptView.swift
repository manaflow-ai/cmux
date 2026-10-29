public import AppKit
import CmuxNextCompat
public import CmuxHomeCore
public import CmuxHomeRender
public import CmuxNextDesign
public import MessagesLabHome

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
    var starterSent = false
    var starterIntakes = 0 { didSet { updateStarterAvailability() } }
    let me: ParticipantID
    /// This conversation's part of the store: chained refusal and
    /// unanswered callbacks, attachment bytes, Cancel Upload.
    public let binding: HomeStoreBinding
    /// The notice above the field (an attachment refused, a send refused in
    /// the background, an op that may not have gone through).
    let noticeLabel = ChromeLabel(wrappingLabelWithString: "")
    private(set) var notice: String?
    /// The notice's one action under it (Open System Settings for a denied microphone).
    let noticeButton = NSButton(title: "", target: nil, action: nil)
    private(set) var noticeAction: HomeNoticeAction?
    /// The message box's mic (Debug Settings > Home > Mic button in the message box).
    let voice = HomeVoiceDictation()
    /// Prepares dropped, pasted and picked files (the data side; the store
    /// by default, a recorder in tests). Nil: the composer takes none.
    public var attachmentPreparer: (any HomeAttachmentPreparing)?
    /// The "+" file picker over the app's made-ahead panel; nil when the app passed none (tests).
    let attachmentPanel: HomeAttachmentPanel?
    /// Whether photos and videos keep their location (Settings > Home,
    /// `home.attachments.keepLocation`; false strips it, the default).
    public var keepLocation: () -> Bool = { false }
    /// The chain of attachment preparations, in the order they arrived.
    // task-owner: replaced by the next intake; awaited by attachmentsReady
    var intake: Task<Void, Never>?
    /// The pane's drop target state: its highlight, the current drag's answer, drops on their way.
    let drop = HomeDropState()
    private(set) var stopped = false
    /// The composer rect toasts last moved clear of (posted on change).
    private var lastToastAvoidance = NSRect.zero
    /// False while the owner is unreachable (H17: offline Send is off; the
    /// text stays a draft). The wiring sets it from `HomeStore.connection`.
    public var isSendEnabled = true {
        didSet { transcript.isSendEnabled = isSendEnabled; updateStarterAvailability() }
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
    /// Forward… on a bubble: the host routes its text to another chat (nil: no Forward…).
    public var onForward: ((String) -> Void)? {
        get { transcript.onForward }
        set { transcript.onForward = newValue }
    }
    /// A click on any other link in the transcript (`otherTarget`: Shift-Command held).
    public var onOpenLink: (_ url: URL, _ otherTarget: Bool) -> Void {
        get { transcript.onOpenLink }
        set { transcript.onOpenLink = newValue }
    }
    /// A press on a link that moved past the drag slop (the pointer's screen point): true when the
    /// host took it as a link drag (a split or pane drop zone opens it). Nil: the press selects text.
    public var onDragLink: ((_ url: URL, _ screenPoint: CGPoint) -> Bool)? {
        get { transcript.onDragLink }
        set { transcript.onDragLink = newValue }
    }

    /// Where an attachment opens and what its right-click menu offers (held weakly; the host
    /// keeps it). Nil: the system opens it.
    public var fileHost: HomeFileHost? {
        get { transcript.fileHost }
        set { transcript.fileHost = newValue }
    }
    /// The host's shared stop action.
    public var onStop: () -> Void = {} {
        didSet { transcript.onStop = { [weak self] in self?.onStop() } }
    }
    /// A chosen sent-bubble colour (opt in); nil keeps the style's (iMessage blue, or the theme's accent).
    public var accentOverride: NSColor? { didSet { applyTheme() } }
    /// The bubbles' look: iMessage's (the default) or the theme's colours; follows
    /// `home.chiefBubbleStyle` (`DesignSettings.homeChiefBubblesThemed`, `followBubbleStyle`).
    public var bubbleStyle: HomePalette.BubbleStyle = .iMessage { didSet { if bubbleStyle != oldValue { applyTheme() } } }
    /// This chat's chosen bubble colours over the default for every chat (Chat Colors…,
    /// `home.bubbleColors.*`); empty keeps the bubble style's colours.
    public var bubbleColors = HomeBubbleColors() { didSet { if bubbleColors != oldValue { applyTheme() } } }
    /// The chats' own colours (Chat Colors…): set, the view follows this conversation's, live, over the
    /// default for every chat (`home.bubbleColors.*`, ``bubbleColors``). Nil keeps ``bubbleColors`` as set.
    public var chatColors: HomeChatColorStore? { didSet { if chatColors !== oldValue { followChatColors() } } }
    /// The conversation this view shows (the key of its ``chatColors``).
    public let conversationID: ConversationID
    /// The first-run panel's open-a-terminal or start-an-agent row was
    /// picked (the host runs the matching registry action).
    public var onFirstRunAction: (HomeFirstRunAction) -> Void = { _ in }
    /// An agent row of the first-run panel was picked: the host opens that
    /// tab (its daemon tab id).
    public var onFirstRunAgent: (String) -> Void = { _ in }
    /// The Switching card's Hide: the host records it, then clears the card.
    public var onHideSwitchKeys: () -> Void = {}
    /// The Switching card's Keyboard Shortcuts… button (the Mission Control note).
    public var onOpenKeyboardShortcutSettings: () -> Void = {}
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
    /// A click on a header panel toggle (``setHeaderPanels(_:)``), by its id.
    public var onHeaderPanel: (String) -> Void = { _ in }
    /// The header's top-right panel toggles (HomeNativeTranscriptView+HeaderPanels.swift).
    let headerPanels = HomeHeaderPanelBar()
    /// The window's key and occlusion observers; each token removes itself when released (on any thread).
    private var observers: [MainActorObservation] = []
    /// The window's typing hold for the compose field's cursor rects (HomeCursorRectHold).
    private var cursorHold: HomeCursorRectHold?
    /// Debug Settings > Home > Avatar and name over the chat, when this conversation opened (off: no header).
    let showsHeader = HomeTunables.chatHeader.value

    /// - Parameter diagrams: draws Mermaid fences as diagrams (the app's ``OndineMermaidRenderer``); nil keeps them as text.
    /// - Parameter openPanel: the app's made-ahead file picker (`AppServices.openPanel`) for the "+"; nil (tests) opens none.
    public init(store: HomeStore, conversation: ConversationID, me: ParticipantID, diagrams: (any HomeDiagramRendering)? = nil,
                openPanel: MadeAheadOpenPanel? = nil) {
        attachmentPanel = openPanel.map { HomeAttachmentPanel(openPanel: $0) }
        HomeReduceMotion.install()
        self.me = me
        // Debug Settings > Home > Rich tables, before the transcript maps its first messages.
        MessagesLabHomeView.richTables = HomeTunables.richTables.value
        conversationID = conversation
        transcript = MessagesLabHomeView(store: store, conversation: conversation, me: me, wake: HomeDemandWake(), diagrams: diagrams)
        // The running indicator's look (Debug Settings > Home), read at each of its ticks.
        transcript.turnProgressStyle = { HomeTunables.turnProgress.value.style }
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
        noticeButton.isBordered = false
        noticeButton.font = Typography.caption
        noticeButton.isHidden = true
        noticeButton.target = self
        noticeButton.action = #selector(noticeButtonClicked)
        addSubview(noticeButton)
        connectAttachments()
        connectVoice()
        firstRun.isHidden = true
        firstRun.onAction = { [weak self] action in self?.onFirstRunAction(action) }
        firstRun.onAgent = { [weak self] id in self?.onFirstRunAgent(id) }
        firstRun.starters.onSend = { [weak self] prompt in self?.sendStarter(prompt) }
        firstRun.switchCard.onHide = { [weak self] in
            self?.firstRun.switchCard.apply(nil)
            self?.firstRun.needsLayout = true
            self?.onHideSwitchKeys()
        }
        firstRun.switchCard.onOpenSettings = { [weak self] in self?.onOpenKeyboardShortcutSettings() }
        transcript.onSummaryChange = { [weak self] _ in self?.updateFirstRun() }
        transcript.onRowsChange = { [weak self] in self?.updateFirstRun() }
        // A long draft grows the field with no size change: refit the panel and the notice above it.
        transcript.onFieldTopChange = { [weak self] in self?.needsLayout = true }
        followTextSize()
        followZoom()
        followBubbleStyle()
        followHeroTunable()
        followChiefPet()
        applyTheme()
        followTopFadeStyle()
        updateFirstRun()
    }

    required init?(coder: NSCoder) { nil }


    /// The hover cards of link chips (``enableLinkPreviews(coordinator:previewer:)``), nil until the host enables them.
    private(set) var linkPreviews: HomeLinkChipHoverSource?

    /// Link chips get hover cards from the app's one `coordinator`, filled by `previewer`
    /// (plans/cmux-next/home-link-chips-DESIGN.md). Call once; the source registers while the
    /// transcript is in a window.
    public func enableLinkPreviews(coordinator: HoverCardCoordinator, previewer: any HomeLinkPreviewing) {
        guard linkPreviews == nil else { return }
        let source = HomeLinkChipHoverSource(transcript: transcript, coordinator: coordinator, previewer: previewer)
        linkPreviews = source
        transcript.onPointerMoved = { [weak coordinator] point in coordinator?.pointerMoved(to: point) }
        if window != nil { coordinator.register(source) }
    }

    /// Stops forwarding (the conversation closed). Once.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        if let linkPreviews { linkPreviews.coordinator.unregister(linkPreviews) }
        intake?.cancel()
        voice.close()
        transcript.stop()
        binding.stop()
    }

    nonisolated public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The first-run panel is on screen (capture scenes settle on it).
    public var debugFirstRunShown: Bool { !firstRun.isHiddenOrHasHiddenAncestor && firstRun.window != nil }
    /// The first-run panel's listed agents, most urgent first.
    public var debugFirstRunAgents: [HomeDebugAgentRow] { firstRun.debugAgents }
    /// Clicks the panel's agent row `index` (`HomeFirstRunView.debugClickAgent`).
    public func debugClickFirstRunAgent(_ index: Int, pointer: Bool) -> String? { firstRun.debugClickAgent(index, pointer: pointer) }
    /// How far the first-run panel's lowest shown part sits above the field's top (negative:
    /// it runs under the field); nil when the panel shows nothing.
    public var debugFirstRunFieldGap: CGFloat? {
        firstRun.debugShownBottom.map { transcript.fieldTop - (firstRun.frame.minY + $0) }
    }
    /// Which parts of the first-run panel show (hero, switch_card, action_rows).
    public var debugFirstRunParts: [String: Bool] { firstRun.debugShownParts }
    /// The field's top in this view.
    public var debugFieldTop: CGFloat { transcript.fieldTop }
    /// Puts `text` in the field, as typing would (`home-chief-long-draft`).
    public func debugSetDraft(_ text: String) { transcript.setDraft(text) }
    #endif

    /// A click on the header's name pill (the Chief's settings popover).
    public var onNamePill: () -> Void {
        get { transcript.onNamePill }
        set { transcript.onNamePill = newValue }
    }

    /// The header's name pill, which the Chief's settings popover opens under.
    public var namePill: NSView { transcript.namePill }
    /// The header views that run ``onNamePill`` (the pill and the avatar).
    public var namePillToggles: [NSView] { transcript.namePillToggles }

    /// The header avatar's text; nil shows the conversation's initials.
    public var avatarText: String? {
        get { transcript.avatarText }
        set { transcript.avatarText = newValue }
    }

    /// The header's name (a Chief's own name, its record's); nil shows the conversation's title.
    public var headerTitle: String? {
        get { transcript.headerTitle }
        set { transcript.headerTitle = newValue }
    }

    /// The header avatar's picture, over its text; nil shows the text.
    public var avatarPicture: NSImage? {
        get { transcript.avatarPicture }
        set { transcript.avatarPicture = newValue }
    }

    /// Each Chief's avatar by participant id (``HomeChiefAvatar/bubbleAvatars(for:own:fallback:)``),
    /// beside a group's bubbles; a new value redraws them.
    public func setChiefBubbleAvatars(_ avatars: [String: HomeChiefAvatar]) {
        transcript.setSenderAvatars(avatars.mapValues {
            switch $0 {
            case .picture(let url): .picture(url)
            case .text(let text): .text(text)
            }
        })
    }

    /// The name pill's VoiceOver help.
    public func setNamePillHelp(_ help: String) { transcript.setNamePillHelp(help) }

    /// The header band's height (avatar and name pill), from the top: a control placed under it never covers the name.
    public var headerHeight: CGFloat { transcript.headerHeight }

    /// The primary input (spec/app-screens.md section 3): the message box's
    /// text view. Hosts focus this view, not the transcript.
    public var primaryInput: NSView { transcript.primaryInput }

    /// The host's opt-in system spell checking preference for the native composer.
    public var composerSpellCheckingEnabled: Bool {
        get { transcript.composerSpellCheckingEnabled }
        set { transcript.composerSpellCheckingEnabled = newValue }
    }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(primaryInput) ?? false
    }

    /// The person opened this conversation: the message box takes the keyboard now, or once the
    /// first page installs it if nothing else took the keyboard in between.
    public func takeKeyboardOnOpen() { transcript.takeKeyboardOnOpen() }
    /// Shows `text` in the message box (Send Message… from elsewhere already wrote it to the
    /// store's draft; an open view takes it here, a new one restores it from the store).
    public func showDraft(_ text: String) { transcript.setDraft(text) }

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

    /// Whether a plain Up or Down from `responder` recalls sent messages in
    /// the message box: no while the person moves through the first-run
    /// panel's rows, a text input has the keyboard, or the transcript holds a
    /// text selection.
    /// - Parameter responder: The window's first responder now.
    /// - Returns: True when the host should call ``recallPrimaryInputHistory(older:)``.
    public func primaryInputHistoryTakesArrowKeys(from responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, view.isDescendant(of: firstRun), !firstRun.isHiddenOrHasHiddenAncestor {
            return false
        }
        return transcript.primaryInputHistoryTakesArrowKeys(from: responder)
    }

    /// Up (`older`) or Down from outside the message box: the box takes the
    /// keyboard and recalls a sent message (the draft is kept for Down).
    /// - Parameter older: True for Up, false for Down.
    /// - Returns: True when the box took the key.
    @discardableResult
    public func recallPrimaryInputHistory(older: Bool) -> Bool {
        transcript.recallPrimaryInputHistory(older: older)
    }

    /// Cmd+V from the first-run panel (the transcript's own pane handles it
    /// below this view): the message box takes the keyboard and the paste.
    @objc public func paste(_ sender: Any?) { transcript.pasteIntoPrimaryInput(sender) }

    /// Whether ``paste(_:)`` has text, files or pictures for the message box.
    public var canPasteIntoPrimaryInput: Bool { transcript.canPasteIntoPrimaryInput }

    /// The live interface scale applies to the native first-run chrome, times the Chief chat's zoom
    /// (`followZoom`), so the empty chat's panel grows with the header and field around it. The
    /// MessagesLab transcript owns its own text and field metrics.
    private func followTextSize() {
        withObservationTracking {
            applyTextScale(Typography.userScale * DesignSettings.shared.agentPaneZoom)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followTextSize() }
        }
    }

    /// Agent Chat Zoom (`agentPane.zoom`; Cmd-= / Cmd-- / Cmd-0 on Home, `home.zoomIn`): the Chief chat
    /// is drawn at it, live, as an agent chat is.
    private func followZoom() {
        withObservationTracking {
            transcript.zoom = DesignSettings.shared.agentPaneZoom
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followZoom() }
        }
        needsLayout = true
    }

    /// Settings > Chief > Chief Chat > Bubble Style: iMessage's colours or the theme's, live.
    private func followBubbleStyle() {
        withObservationTracking {
            bubbleStyle = DesignSettings.shared.homeChiefBubblesThemed ? .theme : .iMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followBubbleStyle() }
        }
    }

    /// Chat Colors…: this conversation's colours over the default for every chat, live.
    private func followChatColors() {
        guard let store = chatColors else { return }
        let id = conversationID.rawValue
        withObservationTracking {
            bubbleColors = store.colors(for: id).over(HomeChatColorStore.colors(fromHexes: DesignSettings.shared.homeBubbleColors))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followChatColors() }
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
        // change (`onFieldTopChange` asks for this pass), and the first-run
        // panel fits what it shows above it, under the header.
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
        let action: CGFloat = noticeAction == nil ? 0 : ceil(noticeButton.intrinsicContentSize.height)
        noticeLabel.frame = CGRect(x: 16, y: transcript.fieldTop - height - action - 8, width: width, height: height)
        if noticeAction != nil {
            let w = min(width, ceil(noticeButton.intrinsicContentSize.width))
            noticeButton.frame = CGRect(x: (bounds.width - w) / 2, y: noticeLabel.frame.maxY, width: w, height: action)
        }
        let avoided = toastAvoidanceRect
        if avoided != lastToastAvoidance {
            lastToastAvoidance = avoided
            if let window { CmuxToastAvoidance.avoidanceChanged(in: window) }
        }
    }

    /// Shows (or with nil clears) the notice; VoiceOver hears it.
    public func showNotice(_ text: String?) { showNotice(text, action: nil) }

    /// Shows the notice with one action under it (a link-styled button).
    func showNotice(_ text: String?, action: HomeNoticeAction?) {
        let hadAction = noticeAction != nil
        noticeAction = text == nil ? nil : action
        noticeButton.isHidden = noticeAction == nil
        if let noticeAction {
            noticeButton.attributedTitle = NSAttributedString(string: noticeAction.title, attributes: [
                .font: Typography.caption, .foregroundColor: performWithTheme { Palette.accent }, .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            noticeButton.setAccessibilityLabel(noticeAction.title)
        }
        guard text != notice || hadAction != (noticeAction != nil) else { return }
        notice = text
        noticeLabel.stringValue = text ?? ""
        noticeLabel.isHidden = text == nil
        noticeLabel.setAccessibilityLabel(text)
        if let text {
            NSAccessibility.post(element: noticeLabel, notification: .announcementRequested, userInfo: [.announcement: text])
        }
        layoutNotice()
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
        observers = []
        cursorHold = window.flatMap(HomeCursorRectHold.hold(for:))
        cursorHold?.add(self)
        if let linkPreviews {
            if window == nil || stopped { linkPreviews.coordinator.unregister(linkPreviews) } else { linkPreviews.coordinator.register(linkPreviews) }
        }
        guard let window else { return }
        if attachmentPreparer != nil { attachmentPanel?.warmWhenIdle() }  // the "+" opens without making a panel
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification].map { name in
            MainActorObservation(name, object: window) { [weak self] in self?.windowStateChanged() }
        }
        windowStateChanged()
        // A theme change while the tab was hidden (equal palettes return early).
        applyTheme()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// The theme's palette (the key window's, for every window) for the MessagesLab
    /// Fixture colours, and the first-run panel's colours.
    private func applyTheme() {
        let accent = accentOverride, style = bubbleStyle, chosen = bubbleColors
        let active = performWithTheme { HomeThemePalette.resolveInScope(active: true, style: style, accentOverride: accent) }.applying(chosen)
        // A chosen sent colour replaces MessagesLab's measured blue (and its white text).
        let measured = chosen.sent == nil && chosen.sentText == nil
            && performWithTheme { HomeThemePalette.usesMessagesBlueInScope(style: style, accentOverride: accent) }
        transcript.applyTheme(active: active, measuredAccent: measured)
        // The header's top fade (Debug Settings > Home > Top of the chat; the glass band by default,
        // HeaderGlass.swift), or no header and the rows' own short fade (HomeNativeTranscriptView+TopFade.swift).
        applyTopFadeStyle()
        performWithTheme {
            firstRun.applyColors(primary: Palette.textPrimary, secondary: Palette.textSecondary, tertiary: Palette.textTertiary, fill: Palette.elevatedBackground,
                                 hover: Palette.hoverFill, border: Palette.separator, attention: Palette.attention,
                                 danger: Palette.danger, done: Palette.highlight)
            noticeLabel.textColor = Palette.textSecondary
        }
        drop.highlight.applyTheme()
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

