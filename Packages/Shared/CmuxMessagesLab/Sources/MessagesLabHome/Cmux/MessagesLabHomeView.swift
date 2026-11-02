import AppKit
import CmuxHomeCore
import CmuxHomeRender

/// The Home transcript for one conversation: MessagesLabAppKitNative's host
/// (the vendored `HostView` and `ChatController`, layer order below, scroll,
/// header backdrop, selection, morph, field chrome, compose, above) in a
/// pane, over the HomeStore adapter (`HomeProjection`). The host adds the
/// pane-level parts (the first-run panel, availability) around it.
@MainActor
public final class MessagesLabHomeView: NSView {
    let controller: ChatController
    let projection: HomeProjection
    private var warmed = false
    private var appliedComposerSpellChecking: Bool?
    /// The palette generation this view's rows were last refreshed for (applyTheme).
    private var appliedPalette = -1

    /// - Parameters:
    ///   - store: the app's HomeStore (one per daemon session; the view never creates one).
    ///   - wake: the engine clock's one-shot timer (CmuxNext: DemandTimer).
    ///   - diagrams: draws ```` ```mermaid ```` fences as diagram bubbles (CmuxNext: the
    ///     JavaScriptCore Ondine renderer); nil keeps them as text.
    ///   - replies: how an agent's running reply shows: ``HomeReplyDisplay/wholeMessages`` (default:
    ///     typing dots, then each message whole) or the older token-by-token stream bubble.
    public init(store: HomeStore, conversation: ConversationID, me: ParticipantID, wake: any ChatWakeScheduler,
                diagrams: (any HomeDiagramRendering)? = nil, replies: HomeReplyDisplay = .wholeMessages) {
        MessagesLabHomeView.liveFormatting()
        HomeMarkdownPolicy.install()
        // Before the projection maps its first messages, so a diagram never shows as text first.
        if let diagrams { HomeDiagramRowProvider.install(diagrams) }
        // An agent's pipe tables as full-width table and plan cards (Leo 2026-10-20).
        HomeTableRowProvider.install()
        // Agent-message folds as muted caption lines, not bubbles (user 2026-10-31).
        HomeAgentFoldRowProvider.install()
        controller = ChatController(wake: wake)
        // Link cards fetch their preview (title, image) for links the user or an agent sent (README).
        projection = HomeProjection(store: store, conversation: conversation, me: me, controller: controller,
                                    linkPreviews: HomeLinkPreviews(), replies: replies)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(controller.host)
        projection.start()
        // Reduce Motion changes (the system setting or the host's pin) still or restart the loops
        // already running (MessagesLabHomeView+Motion.swift).
        motionObservers = observeReduceMotion()
    }

    /// The Reduce Motion observers (weak: a closed view's turn is a no-op).
    private var motionObservers: [any NSObjectProtocol] = []
    /// An open came before the message field existed: the field takes the keyboard when it is
    /// installed, if the keyboard is still on `openKeyboardFrom` (the responder then) or nowhere.
    private var openKeyboardWaits = false
    private weak var openKeyboardFrom: NSResponder?
    private var opensOnInstall = false

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Live dates in the user's zone and locale (the vendored formatters
    /// read these once, before the first date is formatted).
    private static func liveFormatting() {
        guard Instant.liveZone == nil else { return }
        Instant.liveZone = .current
        Instant.liveLocale = .current
    }

    /// Stops forwarding (the conversation closed).
    public func stop() {
        projection.stop()
        controller.wake.cancel()
    }

    public override var isFlipped: Bool { true }

    /// MessagesLab b6760b6: Home moved in its pane without a size change (a split or sidebar move that only
    /// shifts it): the typing indicator snaps to the window's device pixels at the new place. A size change
    /// lays the host out, which refreshes it too (HostView.layout).
    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        controller.host.refreshWindowPlaceIfMoved()
    }

    /// cmux: the Chief chat's zoom (Agent Chat Zoom, `agentPane.zoom`; Cmd-= / Cmd-- / Cmd-0 on Home). The
    /// transcript keeps MessagesLab's metrics: it is laid out at this view's size over the zoom and this view's
    /// bounds draw it magnified, as NSScrollView magnification does, so its text, bubbles and field grow together
    /// and the rows wrap to the narrower width. Its bitmaps render at the window's scale times the zoom, so the
    /// magnified text stays sharp. Clamped to 0.5-2.
    public var zoom: CGFloat {
        get { controller.host.contentZoom }
        set {
            let next = newValue.isFinite ? min(max(newValue, 0.5), 2) : 1
            guard next != controller.host.contentZoom else { return }
            controller.host.contentZoom = next
            applyZoomBounds()
            controller.followWindowScale()
            // The field moved with the zoom (the host is now frame / zoom tall) without a frame change here: lay out
            // now so `fieldTop` is current, and tell the host, which lays out what it keeps above the field.
            needsLayout = true
            layoutSubtreeIfNeeded()
            controller.onFieldTopChange?()
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyZoomBounds()
    }

    /// The bounds that draw the host at `zoom`: the frame's size over the zoom, from the origin.
    private func applyZoomBounds() {
        let size = NSSize(width: frame.width / zoom, height: frame.height / zoom)
        if bounds.size != size { setBoundsSize(size) }
        if bounds.origin != .zero { setBoundsOrigin(.zero) }
    }

    public override func layout() {
        super.layout()
        if controller.host.frame != bounds { controller.host.frame = bounds }
        if let compose = controller.demo?.compose, appliedComposerSpellChecking != composerSpellCheckingEnabled {
            compose.textView.view.setSpellCheckingEnabled(composerSpellCheckingEnabled)
            appliedComposerSpellChecking = composerSpellCheckingEnabled
        }
        if !warmed, window != nil, controller.demo != nil {
            warmed = true
            // MessagesLab warms the first send's one-time costs at idle after
            // launch (text system, morph blur); here on first layout.
            ChatController.warmUp()
        }
    }

    // MARK: Host API

    /// The host's notice, the transcript's system row under the newest message (nil: none).
    public var notice: String? {
        get { projection.notice }
        set { projection.notice = newValue }
    }

    /// An agent's pipe tables draw as cards at the chat's full width, assignment tables as the
    /// Chief's plan card (default on; Debug Settings > Home > Rich tables). Off, they stay Markdown
    /// text in the bubble. Messages mapped after the change follow it.
    public static var richTables: Bool {
        get { HomeTableRowProvider.isOn }
        set { HomeTableRowProvider.isOn = newValue }
    }

    /// The Chief's live plan for the plan cards' state pills and owner links (the host copies its
    /// ``ChiefPlanBoard`` here whenever it changes).
    public static func publish(plan: ChiefPlan) {
        HomePlanRowProvider.plan = plan
    }

    /// H17: offline the user can type; tapbacks are off and a send waits as "sending".
    public var isSendEnabled: Bool {
        get { projection.isSendEnabled }
        set { projection.isSendEnabled = newValue }
    }

    /// Whether the native composer opts into the system spell checker. The host owns this
    /// preference; the default is off so opening Home never changes the user's typing behavior.
    public var composerSpellCheckingEnabled = false {
        didSet {
            guard composerSpellCheckingEnabled != oldValue else { return }
            controller.demo?.compose.textView.view.setSpellCheckingEnabled(composerSpellCheckingEnabled)
        }
    }

    /// How the Chief's running indicator reads (``HomeTurnProgressStyle``), asked at each of its ticks:
    /// the host passes its Debug Settings value so a change shows within a second.
    public var turnProgressStyle: () -> HomeTurnProgressStyle {
        get { projection.liveLine.style }
        set { projection.liveLine.style = newValue }
    }

    /// The Chief works: the compose bar offers Stop (the button, Esc, Cmd-.).
    public var isWorking: Bool {
        get { controller.isWorking }
        set { controller.isWorking = newValue }
    }

    /// The host's shared stop action.
    public var onStop: (() -> Void)? {
        get { controller.onStop }
        set { controller.onStop = newValue }
    }

    /// Runs after the daemon accepts a Chief stop, when the stop button
    /// becomes Continue.
    public var onContinue: (() -> Void)? {
        get { controller.onContinue }
        set { controller.onContinue = newValue }
    }

    /// Whether the stopped Chief can be continued from the stop button.
    public var continueAvailable: Bool {
        get { controller.continueAvailable }
        set { controller.continueAvailable = newValue }
    }

    /// The host's Stop all agents: Option-click on the stop button.
    public var onStopAll: (() -> Void)? {
        get { controller.onStopAll }
        set { controller.onStopAll = newValue }
    }

    /// A committed person message in a Chief conversation asks the Chief to
    /// answer that message again. The app supplies the `chief.retry` bridge;
    /// ordinary Home conversations leave it unset.
    public var onChiefRetry: ((MessageID) -> Void)? {
        get { projection.onChiefRetry }
        set { projection.onChiefRetry = newValue }
    }

    /// The stop button's tooltip while the Chief works; nil: "Stop".
    public var stopToolTip: String? {
        get { controller.stopToolTip }
        set { controller.stopToolTip = newValue }
    }

    /// The window is key and visible (read cursor).
    public var isVisibleToUser: Bool {
        get { projection.isVisibleToUser }
        set { projection.isVisibleToUser = newValue }
    }

    /// The theme's palette (the key window's: every Home window draws its
    /// bubbles with it in both key states, MessagesLab 806ef0c / macOS 27), with
    /// this chat's Chat Colors. Each view draws with its own palette
    /// (`PaletteScope`): two chats on screen with different bubble colours keep
    /// their own rows. The process palette (`Fixture.theme` outside a view's
    /// work: its composer and send) is the first view's, then the chat the
    /// person types or clicks in.
    /// `measuredAccent`: the theme names no accent, so sent bubbles keep
    /// MessagesLab's measured blue and gradient.
    public func applyTheme(active: HomePalette, measuredAccent: Bool = false) {
        let theme = FixtureTheme(active: active, measuredAccent: measuredAccent)
        let box = PaletteScope.box(for: theme)
        // Link cards follow a light theme (MessagesLab 02519e9: Messages' light card, #E9E9EB).
        if let demo = controller.demo { demo.setLightAppearance(theme.active.isLight) } else { Fixture.lightAppearance = theme.active.isLight }
        let focused = (controller.host.window?.firstResponder as? NSView)?.isDescendant(of: controller.host) ?? false
        if PaletteScope.process == nil || focused { PaletteScope.claimProcess(box) }
        controller.demo?.setPalette(box)
        PaletteScope.with(box) {
            controller.host.headerBackdrop.setTint(Fixture.background)
            controller.demo?.backgroundColor = Fixture.background
            controller.host.fieldChrome.applyTheme(light: theme.active.isLight, symbol: theme.active.composeText, edge: theme.active.fieldEdge)
            controller.host.paneHeader.light = theme.active.isLight
        }
        // This view draws again whenever its rows were made with another palette (its own applied generation).
        let generation = Fixture.generation(of: box)
        guard let demo = controller.demo, appliedPalette != generation else { return }
        appliedPalette = generation
        demo.scope {
            demo.chrome.setNeedsDisplay(); demo.refreshVisibleCells()
            demo.compose.rescale()  // the placeholder, waveform and chips are drawn once with the palette
        }
    }

    /// cmux: a click on a cmux app link in agent text (`URL.isCmuxAppLink`); the host
    /// opens it in the app (`link.open`). Nil: the link opens nothing.
    public var onAppLink: ((URL) -> Void)? {
        get { controller.onAppLink }
        set { controller.onAppLink = newValue }
    }

    /// cmux: the pointer moved over the transcript, in screen coordinates (nil: it left). The
    /// host's hover cards for link chips follow it (``linkChip(atScreenPoint:)``).
    public var onPointerMoved: ((CGPoint?) -> Void)? {
        get { controller.onPointerMoved }
        set { controller.onPointerMoved = newValue }
    }

    /// cmux: the field's height changed, so ``fieldTop`` moved without a size change (a long
    /// draft, an attachment, a send). The host lays out what it keeps above the field.
    public var onFieldTopChange: (() -> Void)? {
        get { controller.onFieldTopChange }
        set { controller.onFieldTopChange = newValue }
    }

    /// cmux: the link chip under `screenPoint` with its pill's frame on screen, or nil (no chip
    /// there, or the transcript is not in a window). The same hit test as a click.
    public func linkChip(atScreenPoint screenPoint: CGPoint) -> HomeLinkChipHit? {
        let host = controller.host
        guard let window = host.window else { return nil }
        let p = host.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard var hit = controller.linkChip(at: p) else { return nil }
        hit.rect = window.convertToScreen(host.convert(hit.rect, to: nil))
        return hit
    }

    /// cmux: a press on a link that moved past the drag slop, with the pointer's screen point; true
    /// when the host took the drag (it drops the link into a split or a pane). Nil: such a press
    /// selects text, as before.
    public var onDragLink: ((_ url: URL, _ screenPoint: CGPoint) -> Bool)? {
        get { controller.onDragLink }
        set { controller.onDragLink = newValue }
    }

    /// cmux: a click on any other link in the transcript (`otherTarget`: Shift-Command held).
    /// Defaults to the system; the host routes it (cmux: its link setting).
    public var onOpenLink: (_ url: URL, _ otherTarget: Bool) -> Void {
        get { controller.onOpenLink }
        set { controller.onOpenLink = newValue }
    }

    /// cmux: where an attachment opens and what its right-click menu offers (held weakly).
    /// Nil: the system opens it ("Open in Default App").
    public var fileHost: HomeFileHost? {
        get { controller.fileHost }
        set { controller.fileHost = newValue }
    }

    /// A click (or Space/Return with the keyboard) on the header's name
    /// pill: cmux shows the Chief's settings popover under it.
    public var onNamePill: () -> Void {
        get { controller.host.paneHeader.onContact }
        set { controller.host.paneHeader.onContact = newValue }
    }

    /// The header's name pill: the view a popover from it anchors to.
    public var namePill: NSView { controller.host.paneHeader.pill }
    /// The header views a click on which runs ``onNamePill``: the pill and the avatar.
    public var namePillToggles: [NSView] { [controller.host.paneHeader.pill, controller.host.paneHeader.avatar] }

    /// cmux: controls at the header's top right (Home's panel toggles), on the avatar's line.
    /// They get their own clicks; the header's empty space still drags the window. Sized by its
    /// `intrinsicContentSize`; hidden in a pane too narrow to keep it clear of the avatar. Nil: none.
    public var headerTrailingAccessory: NSView? {
        get { controller.host.paneHeader.trailingAccessory }
        set {
            controller.host.paneHeader.trailingAccessory = newValue
            // With no header the rows' top follows the accessory (`HostView.bareRowsTop`).
            controller.host.needsLayout = true
        }
    }

    /// cmux: who else has the conversation open, as faces beside the header's name pill (chat
    /// multiplayer); empty shows none. `label` is what VoiceOver reads for them.
    public func setHeaderFaces(_ faces: [PaneHeaderFace], label: String) {
        controller.host.paneHeader.faces = faces
        controller.host.paneHeader.facesLabel = label
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The header's faces as drawn now, and their VoiceOver label (tests and `debug.home.drive`).
    public var debugHeaderFaces: (faces: [PaneHeaderFace], shown: Bool, label: String) {
        let header = controller.host.paneHeader
        return (header.faces, !header.facesView.isHidden && header.facesView.frame.width > 0, header.facesLabel)
    }
    #endif

    /// The header avatar's text (one or two characters, an emoji); nil
    /// shows the conversation's initials.
    public var avatarText: String? {
        get { projection.initialsOverride }
        set { projection.initialsOverride = newValue }
    }

    /// The letters the header's monogram shows: ``avatarText``, else the monogram of the header's name.
    public var shownInitials: String { controller.host.paneHeader.initials }

    /// The header's name; nil shows the conversation's title.
    public var headerTitle: String? {
        get { projection.titleOverride }
        set { projection.titleOverride = newValue }
    }

    /// The header avatar's picture, drawn over `avatarText` and the
    /// initials; nil shows those.
    public var avatarPicture: NSImage? {
        get { projection.pictureOverride }
        set { projection.pictureOverride = newValue }
    }

    /// A sender's chosen avatar beside a group's bubbles (``setSenderAvatars(_:)``).
    public enum SenderAvatar: Hashable, Sendable {
        /// A picture file.
        case picture(URL)
        /// One or two letters or an emoji, on the grey disc.
        case text(String)
    }

    /// Chosen avatars by participant id (each Chief's, as Home's row draws it), beside a group's
    /// bubbles; anyone not listed draws their initials. A new value redraws those bubbles.
    public func setSenderAvatars(_ avatars: [String: SenderAvatar]) {
        projection.senderAvatars = avatars.mapValues {
            switch $0 {
            case .picture(let url): .image(url.absoluteString)
            case .text(let text): .monogram(text)
            }
        }
    }

    /// The name pill's VoiceOver help (what a click on it does).
    public func setNamePillHelp(_ help: String) {
        controller.host.paneHeader.pill.setAccessibilityHelp(help)
        controller.host.paneHeader.pill.refusesFirstResponder = false
    }

    /// The field's text view (the pane's primary input).
    public var primaryInput: NSView { controller.demo?.compose.textView.view ?? self }

    /// Whether focusing this view should move the keyboard from `responder`
    /// to ``primaryInput``.
    ///
    /// False only while the keyboard is on a text view or text field (the
    /// field itself, the thread header's field, a find field) or on the
    /// transcript while the person makes or holds a text selection there.
    /// - Parameter responder: The window's first responder now.
    /// - Returns: True when the host should make ``primaryInput`` first responder.
    public func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool {
        controller.composeShouldTakeKeyboard(from: responder)
    }

    /// Whether ``pasteIntoPrimaryInput(_:)`` has something to paste: text, or
    /// files and pictures Home's attachment intake takes.
    public var canPasteIntoPrimaryInput: Bool { controller.canPasteIntoCompose() }

    /// Cmd+V from a part of Home that is not a text field: the message box
    /// takes the keyboard, then the paste (text, files and pictures, as a
    /// paste in the box or a drop does).
    /// - Parameter sender: The paste's sender, passed to the box's `paste(_:)`.
    public func pasteIntoPrimaryInput(_ sender: Any?) { controller.pasteIntoCompose(sender) }

    /// After a drop on Home or the file picker: the message box takes the
    /// keyboard with the caret at the end of the draft, and its window
    /// becomes key, so the person can type at once. Call it only for an
    /// entry point aimed at Home (never for automation).
    public func focusPrimaryInputForTyping() { controller.focusComposeForTyping() }

    /// Whether a plain Up or Down arrow from `responder`, while Home has the
    /// keyboard, recalls sent messages in the message box: not from a text
    /// input (it moves its own caret) and not from a transcript text selection.
    /// The box itself answers false: its own key handling recalls there.
    /// - Parameter responder: The window's first responder now.
    /// - Returns: True when the host should call ``recallPrimaryInputHistory(older:)``.
    public func primaryInputHistoryTakesArrowKeys(from responder: NSResponder?) -> Bool {
        controller.historyTakesArrowKeys(from: responder)
    }

    /// Up (`older`) or Down from outside the message box: the box takes the
    /// keyboard, and Up shows the newest sent message (each further Up an
    /// older one; Down steps back toward the draft, which is kept).
    /// - Parameter older: True for Up, false for Down.
    /// - Returns: True when the box took the key.
    @discardableResult
    public func recallPrimaryInputHistory(older: Bool) -> Bool {
        controller.recallHistoryFromOutside(older ? .older : .newer)
    }

    /// The person opened this conversation (a click on its row or pinned tile, Return in the list,
    /// a switch key): the message field takes the keyboard, as in Messages. While the first page
    /// is still loading the field does not exist yet; it takes the keyboard once installed, unless
    /// the keyboard moved somewhere else in between (a click in another field, a text selection).
    /// Never brings the window forward.
    public func takeKeyboardOnOpen() {
        guard !ChatController.noFocus, let window else { return }
        if let field = controller.demo?.compose.textView.view {
            openKeyboardWaits = false
            if window.firstResponder !== field { window.makeFirstResponder(field) }
            return
        }
        openKeyboardWaits = true
        openKeyboardFrom = window.firstResponder
        guard !opensOnInstall else { return }
        opensOnInstall = true
        controller.onInstalled.append { [weak self] _ in self?.finishOpenKeyboard() }
    }

    /// The field is installed: it takes the keyboard for an open that waited, if nothing else took it.
    private func finishOpenKeyboard() {
        guard openKeyboardWaits else { return }
        openKeyboardWaits = false
        guard let window, let field = controller.demo?.compose.textView.view else { return }
        let now = window.firstResponder
        guard now == nil || now === window || (openKeyboardFrom != nil && now === openKeyboardFrom) else { return }
        window.makeFirstResponder(field)
    }

    /// Puts text in the field (first-run suggestions).
    public func setDraft(_ text: String) {
        guard controller.store != nil else { return }
        controller.dispatch(.setDraft(text))
    }

    public var conversationSummary: ConversationSummary? { projection.shownSummary }
    public var isEmpty: Bool { projection.shown.isEmpty && !projection.hasOlder }
    public var onSummaryChange: (ConversationSummary?) -> Void {
        get { projection.onSummaryChange }
        set { projection.onSummaryChange = newValue }
    }
    public var onRowsChange: () -> Void {
        get { projection.onRowsChange }
        set { projection.onRowsChange = newValue }
    }
    public var onRefusal: (HomeIntent, HomeRejection) -> Void {
        get { projection.onRefusal }
        set { projection.onRefusal = newValue }
    }

    /// Forward… in a bubble's context menu: the host routes the bubble's text to another chat
    /// (cmux-next's `home.sendSelectionTo`); nil leaves Forward… out of the menu.
    public var onForward: ((String) -> Void)? {
        get { projection.onForward }
        set { projection.onForward = newValue }
    }

    /// Automation and tests: chooses `title` in the context menu of the shown bubble whose text
    /// is `text`, built and chosen by the right-click's path. False when no such bubble or row shows.
    public func debugChooseMenuItem(_ title: String, onBubble text: String) -> Bool {
        guard let hit = debugBubble(text: text), let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { return false }
        controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
        guard let item = menu.items.first(where: { ($0 as? MenuAction)?.label == title || $0.title == title }),
              let action = item.action else { return false }
        NSApp.sendAction(action, to: item.target, from: item)
        return true
    }

    /// The localized title of a bubble's Forward… row.
    public static var forwardMenuTitle: String { CmuxStrings.forward }

    // MARK: Attachments (lane 16)

    /// The "+" button (the host's file picker).
    public var onPickAttachments: () -> Void {
        get { projection.onPickAttachments }
        set { projection.onPickAttachments = newValue }
    }
    /// A paste in the field: true when the host's intake took the pasteboard.
    public var onAttachmentPasteboard: (NSPasteboard) -> Bool {
        get { projection.onAttachmentPasteboard }
        set { projection.onAttachmentPasteboard = newValue }
    }
    /// The words a paste the intake took carries beside its attachments (nil: none): the
    /// field inserts them at the caret.
    public var attachmentPasteText: (NSPasteboard) -> String? {
        get { projection.onAttachmentPasteText }
        set { projection.onAttachmentPasteText = newValue }
    }
    /// Whether a paste would be taken (types only).
    public var acceptsAttachmentDrag: (NSPasteboard) -> Bool {
        get { projection.acceptsAttachmentDrag }
        set { projection.acceptsAttachmentDrag = newValue }
    }
    /// A drop on the field: true when the host's intake took the drag's pasteboard
    /// (nil: as a paste). A drop on the rest of the pane reaches the host's own view.
    public var onAttachmentDrop: ((NSPasteboard) -> Bool)? {
        get { projection.onAttachmentDrop }
        set { projection.onAttachmentDrop = newValue }
    }
    /// While dragging over the field (types only): whether a drop would be taken (nil: as a paste).
    public var acceptsAttachmentDrop: ((NSPasteboard) -> Bool)? {
        get { projection.acceptsAttachmentDrop }
        set { projection.acceptsAttachmentDrop = newValue }
    }
    /// The field became (true) or stopped being (false) the target of a drag the host takes.
    public var onAttachmentDropTarget: (Bool) -> Void {
        get { projection.onAttachmentDropTarget }
        set { projection.onAttachmentDropTarget = newValue }
    }
    /// The store refused a send's attachment before logging it; the text
    /// and attachments are back in the field.
    public var onAttachmentRefusal: (HomeAttachmentError) -> Void {
        get { projection.onAttachmentRefusal }
        set { projection.onAttachmentRefusal = newValue }
    }
    /// The field's text changed (the host clears its notice).
    public var onDraftTextChange: () -> Void {
        get { projection.onDraftTextChange }
        set { projection.onDraftTextChange = newValue }
    }
    /// Cancel Upload in a bubble's menu (`HomeStoreBinding.cancelSend`).
    public var onCancelSend: (IdempotencyKey) -> Bool {
        get { projection.onCancelSend }
        set { projection.onCancelSend = newValue }
    }
    /// Loads attachment bytes (`HomeStoreBinding.fetchAttachment`): bubble
    /// pictures (`.thumbnail`, a video's `.poster`) and originals on click.
    public var fetchAttachment: (@Sendable (AttachmentRef, AttachmentVariant) async throws -> URL)? {
        get { projection.media.fetch }
        set {
            projection.media.fetch = newValue
            projection.refreshAttachments()
        }
    }

    /// Puts a prepared attachment in the field as a chip (MessagesLab's
    /// draft); its bubble picture is made first.
    public func addDraftAttachment(_ attachment: LocalAttachment) async {
        await projection.addDraft(attachment)
    }

    /// The field's attachments, in the order they arrived.
    public var draftAttachments: [LocalAttachment] { projection.draftAttachments }
    public var isRestoringDraftAttachments: Bool { projection.isRestoringDraftAttachments }

    public func removeDraftAttachment(_ hash: String) { projection.removeDraft(hash) }

    /// The field's text.
    public var draftText: String { controller.store?.state.ui.draft.text ?? "" }

    /// Return in the field: sends the text and the attachments as one message.
    /// Nil when it went (or waits for the owner as "sending"), else why not.
    @discardableResult
    public func sendDraft() -> String? { projection.send() }

    /// Automation (DEBUG socket): a love tapback on the newest incoming (or,
    /// with `mine`, my newest) message through the picker's path (`ChatIntents.react`).
    public func debugTapbackNewestIncoming(mine: Bool = false) -> Bool {
        guard let hit = controller.demo?.lastTextRow(mine: mine) else { return false }
        projection.react(hit.row.ref, .tapback("love"))
        return true
    }

    /// Automation (DEBUG socket): the context menu at the newest text bubble
    /// (mine or incoming), built by the right-click's path
    /// (`ChatController.menu(at:)`): item titles, "-" for a separator,
    /// "[palette]" for a tapback row.
    public func debugMenuTitles(mine: Bool) -> [String]? {
        guard let hit = controller.demo?.lastTextRow(mine: mine),
              let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { return nil }
        controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
        return menu.items.map { $0.isSeparatorItem ? "-" : $0.submenu != nil ? "[palette]" : ($0 as? MenuAction)?.label ?? $0.title }
    }

    /// Automation (DEBUG socket): the field's height and, for the newest
    /// receipt row with a row under it, its top to that row's body (macOS 27
    /// Messages: the field is 30 pt after a send and 31 pt from the first key; 20 pt), and
    /// where the transcript rests (`scrollOffset`, `scrollBottom`, `scrollTop`, `pinned`).
    public func debugGeometry() -> [String: Double] {
        guard let demo = controller.demo else { return [:] }
        var out: [String: Double] = ["fieldHeight": Double(demo.compose.fieldRect.height)]
        // Where the transcript rests: its offset, the bottom (newest message) and top ends, and the pin.
        out["scrollOffset"] = Double(demo.collection.contentOffset.y)
        out["scrollBottom"] = Double(demo.pinnedOffset)
        out["scrollTop"] = Double(demo.minOffset)
        out["pinned"] = demo.store.state.ui.scroll.pinnedToBottom && demo.store.state.atNewest ? 1 : 0
        let rows = demo.model.rows
        // crash program: no index math.
        for (i, row) in rows.enumerated().reversed().dropFirst() where !row.ghost {
            guard case .receipt = row.spec.kind, let next = rows.enumerated().dropFirst(i + 1).first(where: { !$0.element.ghost })?.offset else { continue }
            out["receiptToNextBody"] = Double(demo.layout.contentTop(next) - demo.layout.contentTop(i))
            out["receiptHeight"] = Double(row.spec.height)
            break
        }
        out.merge(debugScaleGeometry()) { $1 }  // the per-view render scale (MessagesLabHomeView+ScaleDebug.swift)
        return out
    }

    /// Automation (DEBUG socket): the typing bubble's body (RowCell.typingBody) in window
    /// coordinates (AppKit: origin at the bottom left), nil when no typing row shows.
    public func debugTypingBubbleFrame() -> CGRect? {
        guard let demo = controller.demo, controller.host.window != nil, let hostLayer = controller.host.layer else { return nil }
        for case let cell as RowCell in demo.collection.visibleCells {
            guard case .typing? = cell.spec?.kind, !cell.isHidden else { continue }
            let inHost = cell.typingBody.convert(cell.typingBody.bounds, to: hostLayer)
            return controller.host.convert(inHost, to: nil)
        }
        return nil
    }

    /// Automation (DEBUG socket): the visible rows as drawn, in window coordinates (AppKit: origin
    /// at the bottom left), top to bottom. A message part gives its bubble body (RowDraw.bodyRect in
    /// the row's content, which RowCell.snapRow moves onto the window's device pixels) and its drawn
    /// balloon (RowDraw.balloon: an outgoing text balloon lies a little inside the body on macOS 27);
    /// a thread preview and any other row give the row's content box (both).
    public func debugRowFrames() -> [(kind: String, key: String, outgoing: Bool, frame: CGRect, balloon: CGRect)] {
        guard let demo = controller.demo, controller.host.window != nil, let hostLayer = controller.host.layer else { return [] }
        var rows: [(kind: String, key: String, outgoing: Bool, frame: CGRect, balloon: CGRect)] = []
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec else { continue }
            let content = cell.contentView.layer
            let kind: String, outgoing: Bool, rect: CGRect, drawn: CGRect
            switch spec.kind {
            case let .part(p):
                kind = { if case .text = p.part { return "text" }; return "part" }()
                outgoing = p.outgoing
                rect = RowDraw.bodyRect(spec)
                drawn = RowDraw.balloon(rect, row: p, scale: demo.renderScale)  // this pane's own scale (258b385)
            case .threadPreview(let pv):
                kind = "preview"; outgoing = pv.outgoing
                rect = CGRect(origin: .zero, size: content.bounds.size); drawn = rect
            default:
                kind = "other"; outgoing = false
                rect = CGRect(origin: .zero, size: content.bounds.size); drawn = rect
            }
            func inWindow(_ r: CGRect) -> CGRect { controller.host.convert(content.convert(r, to: hostLayer), to: nil) }
            rows.append((kind, spec.key, outgoing, inWindow(rect), inWindow(drawn)))
        }
        return rows.sorted { $0.frame.maxY > $1.frame.maxY }
    }

    /// Automation (DEBUG socket): MessagesLab's width pass counters (every window view): passes run and
    /// passes deferred to the next display frame (WindowView's resize pacing).
    public var debugWidthPasses: (passes: Int, deferred: Int) {
        (MessagesWindowView.widthPasses, MessagesWindowView.widthPassesDeferred)
    }
    /// MessagesLab's frame budget for width passes (s): a later width change in a display frame runs at once
    /// while that frame's passes cost less (f11642b resize-pace).
    public var debugWidthPassBudget: Double { Double(MessagesWindowView.widthPassFrameBudget) }

    /// The window view's origin in window points (bottom-left origin), for automation.
    public var debugHostOrigin: CGPoint { controller.host.convert(CGPoint.zero, to: nil) }
    /// The window view's frame in window points (bottom-left origin), for automation (its right edge: a pane
    /// whose width is a fraction of a device pixel).
    public var debugHostFrame: CGRect { controller.host.convert(controller.host.bounds, to: nil) }

    /// Automation (DEBUG socket): the text of the newest `limit` messages
    /// this view holds (its own store), oldest first.
    public func debugMessageTexts(limit: Int = 10) -> [String] {
        guard let store = controller.store else { return [] }
        return store.state.conversation.messages.suffix(limit).map { message in
            message.parts.compactMap { part in
                if case let .text(text, _) = part { return text }
                return nil
            }.joined(separator: "\n")
        }
    }

    /// Automation (DEBUG socket): plays or pauses the newest video bubble
    /// through the click's path (`ChatIntents.toggleVideo`).
    public func debugToggleNewestVideo() -> Bool {
        guard let store = controller.store else { return false }
        for m in store.state.conversation.messages.reversed() {
            for (i, part) in m.parts.enumerated() {
                if case let .attachment(a) = part, a.kind == "video" {
                    projection.toggleVideo(PartRef(messageId: m.id, partIndex: i), a.id)
                    return true
                }
            }
        }
        return false
    }

    /// Automation: opens the newest video bubble in the large viewer through the double-click's
    /// path (`ChatIntents.openVideo`).
    public func debugOpenNewestVideo() -> Bool {
        guard let store = controller.store else { return false }
        for m in store.state.conversation.messages.reversed() {
            for (i, part) in m.parts.enumerated() {
                if case let .attachment(a) = part, a.kind == "video" {
                    projection.openVideo(PartRef(messageId: m.id, partIndex: i), a.id)
                    return true
                }
            }
        }
        return false
    }

    /// Automation (DEBUG socket): clicks the first shown link whose URL starts with `prefix`,
    /// through the click's path (`ChatController.openLink`, so an app link goes to
    /// `onAppLink`); the clicked URL, or nil when no shown link matches.
    public func debugClickLink(prefix: String) -> String? {
        guard let demo = controller.demo else { return nil }
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 3) {
            for x in stride(from: b.minX, to: b.maxX, by: 3) {
                let p = CGPoint(x: x, y: y)
                guard let url = controller.linkURL(at: p), url.absoluteString.hasPrefix(prefix), let hit = demo.hit(p) else { continue }
                return controller.openLink(hit, at: p) ? url.absoluteString : nil
            }
        }
        return nil
    }

    /// Automation (DEBUG socket): a click on the newest thread's "N Replies" or
    /// thread preview through the click's path (`ChatController.clicked`). The
    /// open thread's root (its transcript id) after the click, nil when none opened.
    public func debugOpenNewestThread() -> String? {
        guard let demo = controller.demo else { return nil }
        let cells = demo.collection.visibleCells.compactMap { $0 as? RowCell }
            .map { $0.convert($0.bounds, to: demo) }.sorted { $0.maxY > $1.maxY }
        for r in cells {
            for y in stride(from: r.maxY, to: r.minY, by: -3) {
                for x in stride(from: r.minX, to: r.maxX, by: 3) {
                    let p = CGPoint(x: x, y: y)
                    guard demo.repliesHit(p) != nil else { continue }
                    controller.clicked(p)
                    return debugOpenThread
                }
            }
        }
        return nil
    }

    /// Automation (DEBUG socket): the open thread's root (its transcript id), nil when none is open.
    public var debugOpenThread: String? { controller.store?.state.ui.openThread?.messageId }

    /// Automation (DEBUG socket): Esc through the field's path (`ChatController.escape`).
    public func debugEscape() { controller.escape() }

    /// Automation (DEBUG socket): Reply… in the context menu at the newest text bubble (mine or
    /// incoming), built and chosen by the right-click's path. The open thread's root after it.
    public func debugReplyNewest(mine: Bool) -> String? {
        guard let hit = controller.demo?.lastTextRow(mine: mine),
              let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { return nil }
        controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
        guard let item = menu.items.first(where: { ($0 as? MenuAction)?.label == Strings.menuReplyEllipsis }),
              let action = item.action else { return nil }
        NSApp.sendAction(action, to: item.target, from: item)
        return debugOpenThread
    }

    /// Automation (DEBUG socket): a real Esc key press posted to the app's event queue (local
    /// monitors see it), with the key focus on the window itself (`outside`, as when a terminal
    /// or the sidebar has it) or where it is.
    public func debugPostEscape(outside: Bool) {
        guard let window else { return }
        if outside { window.makeFirstResponder(nil) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    /// Automation (DEBUG socket): scrolls the transcript by `dy` points
    /// through AppKit's scroll view.
    public func debugScroll(by dy: CGFloat) {
        guard let demo = controller.demo else { return }
        controller.host.scrollView.scroll(toModelOffset: demo.collection.contentOffset.y + dy)
    }

    /// Returns when every bubble picture asked for so far is ready (tests).
    public func mediaSettled() async { await projection.media.settled() }

    /// The top of the area under the header (the first-run panel's top); with no header
    /// (``setBareTop()``), the rows' top. In this view's frame (zoomed) points.
    public var headerHeight: CGFloat { (controller.host.bareTop ? controller.host.bareRowsTop : Fixture.headerHeight) * zoom }
    /// The field's top in this view's frame (zoomed) points (the first-run panel's bottom).
    public var fieldTop: CGFloat { controller.demo.map { $0.fieldTop * zoom } ?? frame.height }

    /// Nothing animates and no wake-up is pending (tests, the harness).
    public var isIdle: Bool { controller.isIdle }
}
