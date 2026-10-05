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
        controller = ChatController(wake: wake)
        projection = HomeProjection(store: store, conversation: conversation, me: me, controller: controller)
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

    /// H17: offline the user can type, but Send and tapbacks are off.
    public var isSendEnabled: Bool {
        get { projection.isSendEnabled }
        set { projection.isSendEnabled = newValue }
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
            controller.host.fieldChrome.applyTheme(light: theme.active.isLight, symbol: theme.active.incomingText)
            controller.host.paneHeader.light = theme.active.isLight
        }
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
    public var onRefusal: (HomeIntent, HomeRejection) -> Void {
        get { projection.onRefusal }
        set { projection.onRefusal = newValue }
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
    public func sendDraft() { projection.send() }

    /// Automation (DEBUG socket): a love tapback on the newest incoming
    /// message through the picker's path (`ChatIntents.react`).
    public func debugTapbackNewestIncoming() -> Bool {
        guard let hit = controller.demo?.lastTextRow(mine: false) else { return false }
        projection.react(hit.row.ref, .tapback("love"))
        return true
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

    /// Automation (DEBUG socket): scrolls the transcript by `dy` points
    /// through AppKit's scroll view.
    public func debugScroll(by dy: CGFloat) {
        guard let demo = controller.demo else { return }
        controller.host.scrollView.scroll(toModelOffset: demo.collection.contentOffset.y + dy)
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
