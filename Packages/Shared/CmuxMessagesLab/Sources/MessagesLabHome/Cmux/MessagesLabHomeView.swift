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

    /// - Parameters:
    ///   - store: the app's HomeStore (one per daemon session; the view never creates one).
    ///   - wake: the engine clock's one-shot timer (CmuxNext: DemandTimer).
    public init(store: HomeStore, conversation: ConversationID, me: ParticipantID, wake: any ChatWakeScheduler) {
        MessagesLabHomeView.liveFormatting()
        HomeMarkdownPolicy.install()
        controller = ChatController(wake: wake)
        // Link cards fetch their preview (title, image) for links the user or an agent sent (README).
        projection = HomeProjection(store: store, conversation: conversation, me: me, controller: controller,
                                    linkPreviews: HomeLinkPreviews())
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(controller.host)
        projection.start()
    }

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

    public override func layout() {
        super.layout()
        if controller.host.frame != bounds { controller.host.frame = bounds }
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

    /// H17: offline the user can type; tapbacks are off and a send waits as "sending".
    public var isSendEnabled: Bool {
        get { projection.isSendEnabled }
        set { projection.isSendEnabled = newValue }
    }

    /// The Chief works: the compose bar offers Stop (the button, Esc, Cmd-.).
    public var isWorking: Bool {
        get { controller.isWorking }
        set { controller.isWorking = newValue }
    }

    /// cmux-classic: a typing indicator that goes away leaves at once, with no fade-out ghost
    /// (MessagesLab fades it as Messages does; the Chief's ended turns and approval waits must not
    /// leave a faint bubble under the card or the last reply).
    public var typingLeavesAtOnce: Bool {
        get { controller.typingLeavesAtOnce }
        set { controller.typingLeavesAtOnce = newValue }
    }

    /// The host's shared stop action.
    public var onStop: (() -> Void)? {
        get { controller.onStop }
        set { controller.onStop = newValue }
    }

    /// The window is key and visible (read cursor).
    public var isVisibleToUser: Bool {
        get { projection.isVisibleToUser }
        set { projection.isVisibleToUser = newValue }
    }

    /// The theme's palettes for the key and the non-key window. One theme
    /// per app: the palette is process-wide (`Fixture.theme`).
    /// `measuredAccent`: the theme names no accent, so sent bubbles keep
    /// MessagesLab's measured blue and gradient.
    public func applyTheme(active: HomePalette, inactive: HomePalette, measuredAccent: Bool = false) {
        let theme = FixtureTheme(active: active, inactive: inactive, measuredAccent: measuredAccent)
        defer {
            // Per view: a second Home tab finds the process-wide theme set.
            controller.host.headerBackdrop.setTint(Fixture.background)
            // cmux: the window background is per view too; a view made after the
            // process-wide theme was set would keep the one it was made with.
            controller.demo?.backgroundColor = Fixture.background
            controller.host.fieldChrome.applyTheme(light: theme.active.isLight, symbol: theme.active.incomingText)
            controller.host.fieldChrome.applyGlassTint(FieldChrome.glassTint(light: theme.active.isLight, background: theme.active.background))
            controller.host.paneHeader.light = theme.active.isLight
        }
        // Link cards follow a light theme (MessagesLab 02519e9: Messages' light card, #E9E9EB).
        if let demo = controller.demo { demo.setLightAppearance(theme.active.isLight) } else { Fixture.lightAppearance = theme.active.isLight }
        guard Fixture.theme != theme else { return }
        Fixture.theme = theme
        RowBitmaps.shared.removeAll()
        if let demo = controller.demo {
            let inactiveNow = Fixture.inactive
            demo.setInactive(!inactiveNow)
            demo.setInactive(inactiveNow)
            demo.backgroundColor = Fixture.background
            // The placeholder, waveform and chips are drawn once with the palette.
            demo.compose.rescale()
        }
    }

    /// cmux: a click on a Chief subagent's link in agent text (`URL.isChiefSubagentLink`); the host
    /// opens it in the app (`link.open`). Nil: the link opens nothing.
    public var onAppLink: ((URL) -> Void)? {
        get { controller.onAppLink }
        set { controller.onAppLink = newValue }
    }

    /// A click (or Space/Return with the keyboard) on the header's name
    /// pill: cmux shows the Chief's settings sidebar there.
    public var onNamePill: () -> Void {
        get { controller.host.paneHeader.onContact }
        set { controller.host.paneHeader.onContact = newValue }
    }

    /// The header avatar's text (one or two characters, an emoji); nil
    /// shows the conversation's initials.
    public var avatarText: String? {
        get { projection.initialsOverride }
        set { projection.initialsOverride = newValue }
    }

    /// The header avatar's picture, drawn over `avatarText` and the
    /// initials; nil shows those.
    public var avatarPicture: NSImage? {
        get { projection.pictureOverride }
        set { projection.pictureOverride = newValue }
    }

    /// The name pill's VoiceOver help (what a click on it does).
    public func setNamePillHelp(_ help: String) {
        controller.host.paneHeader.pill.setAccessibilityHelp(help)
        controller.host.paneHeader.pill.refusesFirstResponder = false
    }

    /// cmux: the name pill's hover tooltip (which brain answers); nil
    /// shows its accessibility label, as before.
    public func setNamePillToolTip(_ toolTip: String?) {
        controller.host.paneHeader.pillToolTip = toolTip
    }

    /// The field's text view (the pane's primary input).
    public var primaryInput: NSView { controller.demo?.compose.textView.view ?? self }

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
    /// cmux-classic: an approval card waits for the user's answer (the header shows "Waiting for
    /// you", the field "Allow or deny above to continue"); the host's sidebar can say so too.
    public var isWaitingForApproval: Bool { projection.isWaitingForApproval }
    public var onWaitingForApprovalChange: (Bool) -> Void {
        get { projection.onWaitingForApprovalChange }
        set { projection.onWaitingForApprovalChange = newValue }
    }
    public var onRefusal: (HomeIntent, HomeRejection) -> Void {
        get { projection.onRefusal }
        set { projection.onRefusal = newValue }
    }
    /// cmux-classic: a Chief Cloud result card's Open Workspace: the host opens machine
    /// workspace `workspace` (`ws_…`) of `machine` as a local workspace.
    public var onOpenCloudWorkspace: (_ machine: String, _ workspace: String) -> Void {
        get { projection.onOpenCloudWorkspace }
        set { projection.onOpenCloudWorkspace = newValue }
    }
    /// cmux-classic: a Chief Cloud result card's Open Desktop: the host opens the
    /// machine's interactive display in cmux for inspection or control.
    public var onOpenCloudDesktop: (_ machine: String) -> Void {
        get { projection.onOpenCloudDesktop }
        set { projection.onOpenCloudDesktop = newValue }
    }

    /// cmux-classic: a failed turn's Try Again: run the last message again, then call the
    /// completion with whether that started (ChiefNoticeRows.swift).
    public var onRetryLastTurn: (_ completion: @escaping (Bool) -> Void) -> Void {
        get { projection.onRetryLastTurn }
        set { projection.onRetryLastTurn = newValue }
    }

    /// cmux-classic: a saved note's Undo: forget the note `fact`, then call the completion with
    /// whether it was forgotten (ChiefNoticeRows.swift).
    public var onUndoMemory: (_ fact: String, _ completion: @escaping (Bool) -> Void) -> Void {
        get { projection.onUndoMemory }
        set { projection.onUndoMemory = newValue }
    }

    // MARK: Attachments (lane 16)

    /// The "+" button (the host's file picker).
    public var onPickAttachments: () -> Void {
        get { projection.onPickAttachments }
        set { projection.onPickAttachments = newValue }
    }
    /// A paste in the field or a drop on the pane: true when the host's
    /// intake took the pasteboard.
    public var onAttachmentPasteboard: (NSPasteboard) -> Bool {
        get { projection.onAttachmentPasteboard }
        set { projection.onAttachmentPasteboard = newValue }
    }
    /// While dragging (types only): whether a drop would be taken.
    public var acceptsAttachmentDrag: (NSPasteboard) -> Bool {
        get { projection.acceptsAttachmentDrag }
        set { projection.acceptsAttachmentDrag = newValue }
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

    public func removeDraftAttachment(_ hash: String) { projection.removeDraft(hash) }

    /// The field's text.
    public var draftText: String { controller.store?.state.ui.draft.text ?? "" }

    /// Return in the field: sends the text and the attachments as one message.
    /// Nil when it went (or waits for the owner as "sending"), else why not.
    @discardableResult
    public func sendDraft() -> String? { projection.send() }


    /// `y` within `min ... max` (`min` when the range is empty or not finite). Pure, for tests.
    static func clampedScrollOffset(_ y: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard y.isFinite, lo.isFinite, hi.isFinite else { return lo.isFinite ? lo : 0 }
        return Swift.min(Swift.max(y, lo), Swift.max(lo, hi))
    }

    /// Returns when every bubble picture asked for so far is ready (tests).
    public func mediaSettled() async { await projection.media.settled() }

    /// The top of the area under the header (the first-run panel's top).
    public var headerHeight: CGFloat { Fixture.headerHeight }
    /// The field's top in this view (the first-run panel's bottom).
    public var fieldTop: CGFloat { controller.demo?.fieldTop ?? bounds.height }

    /// Nothing animates and no wake-up is pending (tests, the harness).
    public var isIdle: Bool { controller.isIdle }
}
