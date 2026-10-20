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

    #if DEBUG
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
    /// Messages: the field is 30 pt after a send and 31 pt from the first key; 20 pt).
    public func debugGeometry() -> [String: Double] {
        guard let demo = controller.demo else { return [:] }
        var out: [String: Double] = ["fieldHeight": Double(demo.compose.fieldRect.height)]
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
            // A row that already left (a ghost fading out, or cut at once) is not on screen.
            if let ip = demo.collection.indexPath(for: cell), demo.model.rows[checked: ip.item]?.ghost == true { continue } // checked
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
    /// through AppKit's scroll view. cmux-classic: within the content (the oldest
    /// loaded row under the header to the pin), as a wheel stops there; the clip
    /// view's `scroll(to:)` does not constrain, and `--dy 2000` showed a blank
    /// transcript past the last row. It chooses a place as the person's scroll does.
    public func debugScroll(by dy: CGFloat) {
        guard let demo = controller.demo else { return }
        let y = Self.clampedScrollOffset(demo.collection.contentOffset.y + dy, min: demo.minOffset, max: demo.pinnedOffset)
        controller.host.scrollView.scroll(toModelOffset: y)
        controller.host.noteChosenPlace()
    }

    #endif

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
