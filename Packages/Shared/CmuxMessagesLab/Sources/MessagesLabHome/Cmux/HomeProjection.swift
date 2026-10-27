import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Observation
import os

/// The adapter between HomeStore (the single writer of the transcript,
/// plans/cmux-next/home-mac.md section 2) and the vendored MessagesLab
/// controller. HomeStore snapshots become MessagesLab actions on the
/// projection store (`HomeDiff`); the user's sends and tapbacks become
/// `HomeIntent`s with their idempotency keys. The projection never decides
/// what is in the transcript; it only animates what HomeStore says.
///
/// A send: the draft goes to `HomeStore.perform(.sendMessage)` with a fresh
/// key, and `.send` is dispatched on the projection in the same turn, so the
/// morph flies at the press as in MessagesLab. A draft with URL-only lines
/// is logged at once as its plain text, then sent once their previews
/// answered (`HomeLinkSend`: `link_preview` parts with the pictures uploaded
/// as records), as iMessage sends after its loading card. The local message keeps its
/// reducer id (`aliases[key]`); HomeStore's pending item and committed echo
/// carry the key, so they only change its status. A send the owner refuses
/// before logging it leaves the projection (rebuild) and its text returns to
/// the field.
@MainActor
final class HomeProjection: @preconcurrency ChatIntents {
    let homeStore: HomeStore
    let conversation: ConversationID
    let me: ParticipantID
    let controller: ChatController
    /// False while the owner is unreachable (H17: tapbacks off). A send then
    /// waits in HomeStore's offline queue as "sending" (cx-ebm.55).
    var isSendEnabled = true
    /// The host's notice, MessagesLab's system row under the newest message (nil: none).
    var notice: String? {
        didSet { if notice != oldValue, controller.store != nil { controller.dispatch(.cmuxNotice(shownNotice)) } }
    }
    /// The send's own notice (a held send, text carried from a gone
    /// conversation: cx-ebm.55); it shows over the host's notice.
    private var sendNotice: String? {
        didSet { if sendNotice != oldValue, controller.store != nil { controller.dispatch(.cmuxNotice(shownNotice)) } }
    }
    private var shownNotice: String? { sendNotice ?? notice }
    /// The Chief's activity line under the transcript (`chief-live-v1`).
    let liveLine = HomeLiveLine()
    /// The status line's details, made on the first click.
    private(set) var turnPopover: HomeTurnStatusPopover?
    /// The window is key and visible: the read cursor may advance.
    var isVisibleToUser = false { didSet { if isVisibleToUser { reportReadIfNeeded() } } }
    var onSummaryChange: (ConversationSummary?) -> Void = { _ in }
    var onRowsChange: () -> Void = {}
    /// A refused tapback (a refused send restores its draft instead).
    var onRefusal: (HomeIntent, HomeRejection) -> Void = { _, _ in }

    // Attachments (lane 16): the host owns the intake (picker, paste and
    // drop checks, preparing through HomeStore, notices); the chips, the
    // morph and the bubbles are MessagesLab's.
    /// The "+" button.
    var onPickAttachments: () -> Void = {}
    /// A paste or a drop; true when taken.
    var onAttachmentPasteboard: (NSPasteboard) -> Bool = { _ in false }
    /// The words beside the attachments a taken paste carries; nil when none.
    var onAttachmentPasteText: (NSPasteboard) -> String? = { _ in nil }
    /// Whether a paste would be taken, types only.
    var acceptsAttachmentDrag: (NSPasteboard) -> Bool = { _ in false }
    /// A drop on the field; true when taken. Nil takes it as a paste.
    var onAttachmentDrop: ((NSPasteboard) -> Bool)?
    /// While dragging over the field, types only. Nil answers as for a paste.
    var acceptsAttachmentDrop: ((NSPasteboard) -> Bool)?
    /// The field became or stopped being the target of a drag the host takes.
    var onAttachmentDropTarget: (Bool) -> Void = { _ in }
    /// The store refused a send's attachment before logging it; the draft is back.
    var onAttachmentRefusal: (HomeAttachmentError) -> Void = { _ in }
    /// The field's text changed.
    var onDraftTextChange: () -> Void = {}
    /// Forward… on a bubble (u5402): the host asks where its text goes; nil offers no Forward….
    var onForward: ((String) -> Void)?
    /// Cancel Upload (`HomeStoreBinding.cancelSend`).
    var onCancelSend: (IdempotencyKey) -> Bool = { _ in false }
    /// Bubble pictures and originals.
    let media = HomeMedia()
    /// Inline video playback in the bubbles.
    let video = HomeVideo()
    /// Prepared attachments in the field by content hash (the chips are
    /// MessagesLab's draft; a removed chip's entry is ignored).
    private var drafts: [String: LocalAttachment] = [:]
    /// The last launch's attachments are going back in the field: each one
    /// is not written back on its own, the whole field is once they are in.
    private var restoringDraftAttachments = false
    /// Return was pressed while they were still going back: the send goes once the last one is
    /// in, in the thread it was held for (nil: the open view), so none is left out of it.
    private var sendWhenRestored = false
    private var restoredSendThread: (root: MessageID?, parent: MessageID?)?

    /// What the projection shows, as HomeStore said it (shared with the harness).
    private(set) var core: ProjectionCore
    var shown: [TranscriptItem] { core.shown }
    var shownSummary: ConversationSummary? { core.summary }
    var aliases: [IdempotencyKey: ID] { core.aliases }
    private(set) var hasOlder = false
    /// An older page was asked for and has not come yet (one ask per page).
    private var olderRequested = false
    private var reportedRead: Seq = 0
    private(set) var stopped = false
    /// Return was pressed while only the cache knew this conversation: the
    /// send goes once the owner confirms it (`refresh`), in the thread that
    /// was open at the Return (`deferredThread`, nil root: the conversation), answering the
    /// branch message that was open (nil parent: the root).
    private var sendWhenConfirmed = false
    private var deferredThread: (root: MessageID?, parent: MessageID?) = (nil, nil)
    /// A permalink's message waiting for the window that holds it (`reveal`, HomeProjection+Tree.swift).
    var pendingReveal: MessageID?
    /// Tree threads: permalink paging, the thread header, Copy Link (HomeProjection+ThreadHeader.swift).
    let tree = HomeTreeState()
    /// One streamed-text commit per display frame (HomeStreamPacer).
    let streamPacer = HomeStreamPacer()
    /// Rebuilds and applied (changed) updates, for tests.
    private(set) var rebuilds = 0
    private(set) var appliedUpdates = 0
    /// Store reads of this conversation (`refresh`), changed or not (tests: traffic for other conversations costs none).
    private(set) var refreshPasses = 0
    /// This conversation's store inputs at the last observed pass (HomeProjection+Observe.swift): a
    /// change to another conversation wakes the observation, not the transcript.
    var observedInputs: HomeProjectionInputs?
    /// A store pass waits for the next display frame (a keystroke's frame is open); one at a time.
    var heldPass = false

    /// Link card previews (MessagesLab's guarded HTML/image fetcher): fetched once per URL for
    /// links this Mac sends or the user taps; nil keeps domain cards.
    let linkPreviews: HomeLinkPreviews?

    init(store: HomeStore, conversation: ConversationID, me: ParticipantID, controller: ChatController,
         linkPreviews: HomeLinkPreviews? = nil, replies: HomeReplyDisplay = .wholeMessages) {
        homeStore = store
        self.linkPreviews = linkPreviews
        self.conversation = conversation
        self.me = me
        self.controller = controller
        core = ProjectionCore(me: me)
        core.replies = replies
        let media = self.media
        core.media = { [weak media] in media?.asset($0) }
        if let linkPreviews { core.links = { [weak linkPreviews] in linkPreviews?.cached($0) } }
        controller.intents = self
        liveLine.dispatch = { [weak controller] text in if controller?.store != nil { controller?.dispatch(.setNotice(text)) } }
        liveLine.onTick = { [weak self] in self?.turnPopover?.refresh() }
        liveLine.onClose = { [weak self] in self?.turnPopover?.close() }
        video.controller = controller
        // A finished picture redraws only the rows that show it (not every attachment row shown).
        media.onReady = { [weak self] hash in self?.refreshAttachments(only: hash) }
    }

    func start() {
        refresh()
        noteObservedInputs()
        observe()
    }

    func stop() {
        stopped = true
        homeStore.stopTyping(in: conversation)
        liveLine.stop()
        turnPopover?.close()
        controller.intents = nil
    }

    // MARK: HomeStore -> projection

    func refresh() {
        refreshPasses += 1
        if sendWhenConfirmed, homeStore.isConfirmed(conversation) {
            sendWhenConfirmed = false
            sendNotice = nil
            _ = send(thread: deferredThread)
            deferredThread = (nil, nil)
        }
        // One value: the transcript and its running replies, in display order (HomeTimeline).
        let live = homeStore.liveRun(in: conversation)
        let timeline = homeStore.timeline(for: conversation)
        apply(items: timeline.items, summary: homeStore.summary(conversation),
              typing: homeStore.typists(in: conversation),
              hasOlder: homeStore.hasOlderMessages(in: conversation), streams: timeline.streams)
        // The line closes on the frame after the one that shows the reply in the bubble's place (cx-zz30r, cx-06vn1).
        if let activity = live?.activity { liveLine.show(activity, thought: live?.thought) } else { liveLine.hide(after: controller) }
        revealIfLoaded()
        refreshThreadHeader()
    }

    /// The whole current value; unchanged values return before any work.
    func apply(items: [TranscriptItem], summary: ConversationSummary?, typing wantedTyping: Set<ParticipantID>,
               hasOlder newHasOlder: Bool, streams: [HomeStreamRow] = []) {
        // MessagesLab hides a sender's typing dots while its stream has text (ask 11). Whole
        // messages: each running reply is its author's typing dots until its messages post.
        let typing = wantedTyping.union(core.replyTypists(streams))
        guard let store = controller.store else {
            install(items: items, summary: summary, typing: typing, hasOlder: newHasOlder)
            // One read of the kept draft: its text holds a mark where each picture sat (Draft+InlineMarks.swift).
            let kept = homeStore.draft(for: conversation)
            restoreDraft(kept)
            restoreDraftAttachments(into: kept)
            // Replies already running when the view opens show as their streams at once.
            if let store = controller.store { for a in core.streams(streams, state: store.state) { controller.dispatch(a) } }
            return
        }
        let typingChanged = Set(store.state.ui.typing) != Set(typing.filter { $0 != me }.map(\.rawValue))
        // Only the running replies' text changed (a token): at most one such commit per display frame,
        // never ahead of a keystroke (HomeStreamPacer; home-streaming-perf-DESIGN.md). Any other
        // change commits now, with the newest stream text.
        let streamOnly = items == shown && summary == shownSummary && !typingChanged && newHasOlder == hasOlder
        guard !streamOnly || core.streamsDiffer(streams) else { return }
        if streamOnly, !streamPacer.admit(inputFrame: controller.inKeystrokeFrame, nextFrame: controller.nextFrame,
                                          refresh: { [weak self] in if let self, !self.stopped { self.refresh() } }) { return }
        appliedUpdates += 1
        // A new oldest message is the page asked for, however it arrives: a
        // `.prependPage`, or a whole-window rebuild (that one carries no
        // prepend action, and the ask would stay open for good).
        if newHasOlder != hasOlder || items.first?.key != shown.first?.key { olderRequested = false }
        hasOlder = newHasOlder
        let titleChanged = HomeMapping.title(summary, me: me) != HomeMapping.title(shownSummary, me: me)
        let summaryChanged = summary != shownSummary
        let diff = core.step(items: items, summary: summary)
        let streamed = core.streams(streams, state: store.state)
        // MessagesLab bd65bbf: a keystroke goes first. Statuses and typing that arrive in a
        // keystroke frame are committed at the start of the next display frame; anything
        // else (a message, a tapback, a page) is committed now, in order.
        let typingActions = core.typing(store.state, wanted: typing)
        let ambient = !diff.rebuild && streamed.isEmpty && (diff.actions + typingActions).allSatisfy {
            switch $0 { case .status, .typing: return true; default: return false }
        }
        if ambient, controller.inKeystrokeFrame, !(diff.actions + typingActions).isEmpty {
            let held = diff.actions
            controller.nextFrame { [weak self] in
                guard let self, !self.stopped, let store = self.controller.store else { return }
                for a in held { self.controller.dispatch(a) }
                // Typing against the projection then (a receive in between may have ended it).
                for a in self.core.typing(store.state, wanted: typing) { self.controller.dispatch(a) }
                self.onRowsChange()
            }
        } else {
            // The running replies' streams go after the new messages (they stay the newest bubbles), or
            // where a posted reply is among them (`.streamEnd(replacedBy:)`, in transcript order; HomeDiff
            // rebuilds when that order is not the store's).
            let cut = diff.handOffAt ?? diff.actions.count
            for (i, a) in diff.actions.enumerated() {
                if i == cut { dispatchStreamed(streamed) }
                if case .prependPage = a { olderRequested = false }
                controller.dispatchTimingTapback(a) // my tapback chosen in the menu: from its input (MessagesLab 7518134)
            }
            if cut >= diff.actions.count { dispatchStreamed(streamed) }
            // The store's order is the only order (plans/cmux-next/home-chat-pipeline-DESIGN.md 2.3): a
            // projection that came out of these actions in another order is rebuilt in the store's.
            if diff.rebuild || !orderMatchesStore() { rebuild() }
            for a in core.typing(store.state, wanted: typing) { controller.dispatch(a) }
        }
        // A token moves rows (the inline videos follow) and changes nothing else this side tracks:
        // no attachment, title, summary, read cursor or older page work per token.
        video.place()
        if streamOnly { return }
        if titleChanged { applyHeader() }
        refreshAttachments()
        if summaryChanged { onSummaryChange(summary) }
        onRowsChange()
        askForOlderIfNeeded()
        reportReadIfNeeded()
    }

    private func install(items: [TranscriptItem], summary: ConversationSummary?, typing: Set<ParticipantID>, hasOlder: Bool) {
        let (conv, w) = core.install(conversation, items: items, summary: summary)
        self.hasOlder = hasOlder
        let store = controller.install(conv, windowStart: w.start, total: w.total)
        store.linkPreviews = linkPreviews
        installThreadHeader()
        if let previews = linkPreviews?.previews {
            // A historical outgoing card on screen may receive a late answer from the guarded
            // parser; no system preview provider or unguarded subresource loader runs.
            previews.onLateMetadata = { [weak self] url, meta in
                guard let self, !self.stopped else { return }
                self.controller.dispatch(.linkMetadata(url: url, title: meta.title, site: meta.site, image: meta.image))
            }
        }
        applyHeader()
        for a in core.typing(store.state, wanted: typing) { controller.dispatch(a) }
        if homeStore.takeCarriedDraft(conversation) { sendNotice = CmuxStrings.chiefRestarted }
        if shownNotice != nil { controller.dispatch(.cmuxNotice(shownNotice)) }
        liveLine.resend()
        refreshAttachments()
        onSummaryChange(summary)
        onRowsChange()
    }

    /// True when the projection's messages that the store shows are in the store's order, and my
    /// sends the store does not list yet come after them. The projection may hold only a window of
    /// the rows (evictions), so this compares the rows both hold.
    func orderMatchesStore() -> Bool {
        guard let store = controller.store else { return true }
        let want = shown.map { HomeMapping.id($0, aliases: aliases) }
        let wanted = Set(want)
        let have = store.state.conversation.messages.map(\.id)
        let held = Set(have)
        let common = have.filter { wanted.contains($0) }
        guard common == want.filter({ held.contains($0) }) else { return false }
        // Rows the store does not list (my local bubbles before HomeStore logs them) only at the end.
        return have.drop(while: { wanted.contains($0) }).allSatisfy { !wanted.contains($0) }
    }

    /// The whole window again, without animation (MessagesLab has no action
    /// for it): `.replaceWindow`, then the pin or the first visible row's
    /// window position is restored.
    private func rebuild() {
        guard let demo = controller.demo, let store = controller.store else { return }
        rebuilds += 1
        let pinned = store.state.ui.scroll.pinnedToBottom
        let anchor = demo.anchorProbe
        let roots = HomeMapping.roots(in: shown, aliases: aliases, summary: shownSummary, media: core.media, links: core.links)
        let msgs = shown.map { HomeMapping.message($0, aliases: aliases, me: me, summary: shownSummary, media: core.media, links: core.links, roots: roots) }
        let pendingLocal = store.state.conversation.messages.filter { m in
            aliases.contains { $0.value == m.id } && !msgs.contains { $0.id == m.id }
        }
        controller.dispatch(.replaceWindow(msgs + pendingLocal, start: HomeMapping.window(shown).start))
        if pinned {
            controller.dispatch(.setScroll(offset: 0, pinned: true))
            demo.pinToBottom()
            controller.afterEngine()
        } else if let anchor, let i = demo.model.index[anchor.key] {
            controller.host.scrollView.scroll(toModelOffset: demo.layout.contentTop(i) + MessagesWindowView.cvTop - anchor.y)
        }
    }

    /// A chosen avatar text (the Home Chief's avatar), over the initials.
    var initialsOverride: String? { didSet { applyHeader() } }
    /// A chosen avatar picture (the Home Chief's), over the initials.
    var pictureOverride: NSImage? { didSet { controller.host.paneHeader.picture = pictureOverride } }

    /// Chosen sender avatars by participant id (each Chief's, as Home's row draws it), beside a
    /// group's bubbles over the initials; a new value redraws those bubbles.
    var senderAvatars: [String: Participant.Avatar] {
        get { core.avatars }
        set {
            guard !stopped, let action = core.setAvatars(newValue) else { return }
            controller.dispatch(action)
        }
    }

    private func applyHeader() {
        controller.host.paneHeader.title = HomeMapping.title(shownSummary, me: me)
        controller.host.paneHeader.initials = initialsOverride ?? HomeMapping.initials(shownSummary, me: me)
    }

    // MARK: Projection -> HomeStore (intents)

    var canReact: Bool { isSendEnabled }
    /// A reply goes out as `HomeOp.sendMessage(threadRoot:)` (swipe-to-reply,
    /// Reply… in the menu, "N Replies" opens the thread view). Offline it
    /// waits in HomeStore's queue like any send.
    var canReply: Bool { true }

    /// Sends the field's draft. Nil when it went to HomeStore: committed, or
    /// waiting for the owner as "sending" (HomeStore's offline queue: a
    /// send made while the owner or its connection is still starting goes
    /// at the reconnect, or fails "Not Delivered" at the deadline, never
    /// silently). Else why nothing was sent; the text stays in the field.
    @discardableResult
    func send() -> String? { send(thread: nil) }

    /// `deferred`: the thread (root, parent) a held send was made in (`refresh`); nil reads the open view.
    private func send(thread deferred: (root: MessageID?, parent: MessageID?)?) -> String? {
        guard let store = controller.store else { return noteSend("refused: transcript_not_ready") }
        if restoringDraftAttachments {
            sendWhenRestored = true
            restoredSendThread = deferred
            return noteSend("waiting_for_attachments: sends once the last launch's attachments are back in the field")
        }
        // A stream update held for the next frame (HomeStreamPacer) shows first: the send lands after the reply's newest text.
        if !stopped { streamPacer.flush { refresh() } }
        let draft = store.state.ui.draft
        let typed = draft.plainText.trimmingCharacters(in: .whitespacesAndNewlines)  // without the attachment marks
        let attachments = draft.attachments.compactMap { drafts[$0.id] }
        // MessagesLab d0017ba: the reducer's own rule first (Return with nothing to send does nothing:
        // no .send, no flash, no jump, nothing to HomeStore); then a chip whose attachment is not prepared.
        guard Reducer.canSend(draft), !typed.isEmpty || !attachments.isEmpty else { return noteSend("refused: empty_draft") }
        // The open thread or reply view: the send is a reply in that thread (HomeStore's root id).
        let threadRoot: MessageID?, parent: MessageID?
        if let deferred {
            (threadRoot, parent) = deferred
        } else if let resolved = self.threadRoot(of: draft.replyTo ?? store.state.ui.openThread), let answered = treeParent(of: store.state) {
            (threadRoot, parent) = (resolved, resolved == nil ? nil : answered)
        } else {
            // The root has no message id yet (my send still going) or is not loaded: the view
            // closes with a notice; the text stays, and the next Return sends to the conversation.
            controller.dispatch(.closeThread)
            sendNotice = CmuxStrings.threadRootNotReady
            return noteSend("refused: thread_root_unknown")
        }
        // Only the cache knows this conversation so far: the owner has not
        // answered since launch, and a Chief home made again at the same path
        // has other conversations (cx-ebm.55). The text stays; Home shows the
        // owner's conversation (and carries the text there) once it answers.
        if homeStore.isCacheOnly(conversation) {
            sendWhenConfirmed = true
            deferredThread = (threadRoot, parent)
            let chief = homeStore.summary(conversation)?.participants.contains(where: \.isChief) == true
            sendNotice = chief ? CmuxStrings.waitingForChief : CmuxStrings.waitingToConnect
            return noteSend("waiting_for_owner: sends once the owner confirms this conversation")
        }
        sendNotice = nil
        let key = IdempotencyKey.make()
        // The text and the attachments in the field's order (Draft.pieces). Reply to Selection: the
        // quote goes out as a Markdown blockquote above the reply (ReplyQuote.quoted), in the first
        // text; the local bubble shows it as HomeMapping shows the stored reply.
        var pieces: [HomeSendPiece] = draft.pieces.compactMap { piece in
            switch piece {
            case let .text(t): .text(t)
            case let .attachment(a): drafts[a.id].map { .file($0) }
            }
        }
        if controller.replyQuote != nil {
            if case let .text(t)? = pieces.first { pieces[0] = .text(controller.quotedForSend(t)) } else { pieces.insert(.text(controller.quotedForSend("")), at: 0) }
        }
        let text = HomeSendPiece.text(of: pieces)
        let shownDraft = controller.shownDraftForSend(draft.text)
        controller.replyQuote = nil
        linkPreviews?.allowSend(text)
        // The paths that used to drop a send without a word (cx-ebm.55), one line each,
        // so a lost send in dogfood says which one it took.
        if !homeStore.isOnline { _ = noteSend("queued: the store is offline") }
        if homeStore.summary(conversation) == nil { _ = noteSend("sent: the store has not listed this conversation") }
        if !store.state.atNewest { _ = noteSend("sent: an older window shows, no local bubble") }
        if store.state.atNewest {
            // A reply still streaming stays one bubble, the newest row, below this send: the owner posts it
            // after the send, so it lands in the bubble's place (HomeProjection+Draft, send order).
            if let shownDraft { controller.dispatch(.setDraft(shownDraft)) }
            controller.dispatch(.send)
            // The local bubble morphs into HomeStore's item; without it the item shows on its own.
            _ = core.recordSend(key, in: store.state)
        } else {
            // A window of older messages: no local bubble here, HomeStore's
            // item shows at the newest.
            for a in draft.attachments { controller.dispatch(.removeDraftAttachment(a.id)) }
            controller.dispatch(.setDraft(""))
        }
        homeStore.setDraft("", for: conversation)
        homeStore.setDraftAttachments([], for: conversation)
        for a in attachments {
            media.useLocal(a.files, for: a.ref.hash)
            drafts[a.ref.hash] = nil
        }
        let homeStore = self.homeStore, conversation = self.conversation
        let plain = pieces.map(\.part)
        // Messages' link rule: URL-only lines are cards whose previews this Mac attaches. Each text's
        // MessagesLab parts when it has a card (nil: it goes as it is).
        let shown: [[Part]?] = pieces.map { piece in
            guard case let .text(t) = piece else { return nil }
            let parts = TextParts.parts(for: t)
            return HomeLinkSend.hasLinks(parts) ? parts : nil
        }
        let links = shown.contains { $0 != nil }
            ? HomeLinkSend(previews: linkPreviews, store: homeStore, conversation: conversation) : nil
        // task-owner: one send; ends with the owner's answer
        Task { [weak self] in
            do {
                if let links {
                    // Logged at once as the plain text (a quit or a later send cannot lose or pass it);
                    // the previews fill it before it goes, as the local message flies with the grey card.
                    try await homeStore.send(conversation: conversation, parts: plain, uploads: attachments, key: key,
                                             threadRoot: threadRoot, parent: parent) {
                        var parts: [MessagePart] = [], uploads: [LocalAttachment] = []
                        for (piece, cards) in zip(pieces, shown) {
                            guard let cards else { parts.append(piece.part); continue }
                            guard let filled = await links.parts(cards) else { return (plain, []) }
                            parts += filled.parts
                            uploads += filled.uploads.filter { u in !uploads.contains { $0.ref.hash == u.ref.hash } }
                        }
                        return (parts, uploads)
                    }
                } else if attachments.isEmpty {
                    _ = try await homeStore.perform(.sendMessage(conversation: conversation, parts: plain, threadRoot: threadRoot, parent: parent), key: key)
                } else {
                    try await homeStore.send(conversation: conversation, parts: plain, uploads: attachments, key: key, threadRoot: threadRoot, parent: parent)
                }
            } catch let refusal as HomeAttachmentError {
                self?.sendRefused(key, text: text, attachments: attachments, notice: refusal)
            } catch let rejection as HomeRejection {
                self?.sendRefused(key, text: text, attachments: attachments, rejection)
            } catch {
                // HomeSendState.pendingResend: the store resends with the same key.
                // CancellationError: Cancel Upload removed the row.
            }
        }
        return nil
    }

    /// Logs one send outcome with the store's state; returns `outcome` (a refusal's reason).
    private func noteSend(_ outcome: String) -> String {
        Self.log.notice("home send \(outcome, privacy: .public): conversation \(self.conversation.rawValue, privacy: .public), store_online \(self.homeStore.isOnline), listed \(self.homeStore.summary(self.conversation) != nil)")
        return outcome
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    /// Refused before it reached the log (offline, nothing queues, or an
    /// attachment the owner would refuse): the local message goes and the
    /// text and attachments return. A logged refusal stays as "Not
    /// Delivered" (HomeStore's item).
    func sendRefused(_ key: IdempotencyKey, text: String, attachments: [LocalAttachment] = [], _ rejection: HomeRejection? = nil,
                     notice: HomeAttachmentError? = nil) {
        guard !stopped, !homeStore.transcript(for: conversation).contains(where: { $0.key == key }) else { return }
        core.forget(key)
        rebuild()
        if controller.store?.state.ui.draft.text.isEmpty == true, !text.isEmpty { controller.dispatch(.setDraft(text)) }
        for a in attachments { restoreDraft(a) }
        if let notice { onAttachmentRefusal(notice) }
    }

    // MARK: Attachments

    /// A prepared attachment enters the field as MessagesLab's chip, with its
    /// bubble picture made first (the morph and the bubble show it at once).
    func addDraft(_ attachment: LocalAttachment) async {
        let hash = attachment.ref.hash
        guard !stopped, controller.store?.state.ui.draft.attachments.contains(where: { $0.id == hash }) == false else { return }
        await media.prepare(attachment)
        restoreDraft(attachment)
    }

    /// `offset`: where in the field's text (UTF-16) the attachment goes; nil: the caret, or the end
    /// when the field does not show this draft's text yet.
    private func restoreDraft(_ attachment: LocalAttachment, at offset: Int? = nil) {
        let hash = attachment.ref.hash
        guard !stopped, let store = controller.store, !store.state.ui.draft.attachments.contains(where: { $0.id == hash }) else { return }
        drafts[hash] = attachment
        // In the field's text (Draft+InlineMarks.swift).
        let picture = HomeMapping.attachment(attachment.ref, picture: media.asset(hash), progress: nil)
        controller.dispatch(.attachAt(picture, offset ?? controller.composeCaret()))
        saveDraft()
    }

    /// The field's text, with a mark where each attachment sits, and its attachments in order
    /// into HomeStore's cache: a switch to another chat and back, or a relaunch, puts each one
    /// back in its place (Lawrence 2026-10-23: the pictures came back after all the text).
    private func saveDraft() {
        guard !stopped, !restoringDraftAttachments, let store = controller.store else { return }
        homeStore.setDraft(store.state.ui.draft.text, for: conversation)
        homeStore.setDraftAttachments(draftAttachments, for: conversation)
    }

    /// The field's attachments from the cache, once, into a field without any, each at its mark
    /// in `saved` (the kept text). A kept text whose marks do not match the attachments (one
    /// left the blob cache, or a draft kept before the marks were) puts them after the text, and
    /// so does an edit made while they come back.
    private func restoreDraftAttachments(into saved: String?) {
        guard let store = controller.store, store.state.ui.draft.attachments.isEmpty else { return }
        let kept = homeStore.draftAttachments(for: conversation)
        guard !kept.isEmpty else { return }
        let marks = Draft.markOffsets(saved ?? "")
        let offsets: [Int?] = marks.count == kept.count ? marks : kept.map { _ in nil }
        let text = Draft.stripMarks(saved ?? "")
        restoringDraftAttachments = true
        // task-owner: one restore; ends when the last chip is in the field, or when the view stops
        // (the cache still holds the draft, and a held send stays unsent with it)
        Task { [weak self] in
            for (attachment, offset) in zip(kept, offsets) {
                guard let self, !self.stopped else { return }
                await self.media.prepare(attachment)
                // The k-th mark's offset counts the k marks before it, which are back by now.
                let unedited = Draft.stripMarks(self.controller.store?.state.ui.draft.text ?? "") == text
                self.restoreDraft(attachment, at: unedited ? offset : nil)
            }
            guard let self, !self.stopped else { return }
            self.restoringDraftAttachments = false
            self.saveDraft()
            guard self.sendWhenRestored else { return }
            self.sendWhenRestored = false
            _ = self.send(thread: self.restoredSendThread)
            self.restoredSendThread = nil
        }
    }

    /// The field's attachments, in order.
    var draftAttachments: [LocalAttachment] {
        (controller.store?.state.ui.draft.attachments ?? []).compactMap { drafts[$0.id] }
    }

    func removeDraft(_ hash: String) {
        drafts[hash] = nil
        controller.dispatch(.removeDraftAttachment(hash))
        saveDraft()
    }

    /// Each shown attachment part gets its picture and upload state:
    /// HomeStore's progress and HomeMedia's pictures change no transcript
    /// content, so they reach MessagesLab's message without a transition
    /// (`.cmuxSetAttachment`, the row redraws in place).
    /// `only`: just the items that show this hash (its picture became ready).
    func refreshAttachments(only hash: String? = nil) {
        guard !stopped, let store = controller.store else { return }
        for item in shown where !item.isRetracted && !item.attachmentHashes.isEmpty && (hash.map(item.attachmentHashes.contains) ?? true) {
            for (hash, files) in item.localAttachments { media.useLocal(files, for: hash) }
            let id = HomeMapping.id(item, aliases: aliases)
            guard let message = store.state.message(id) else { continue }
            for part in item.parts {
                if case .linkPreview(let link) = part {
                    refreshLinkPicture(link, in: message)
                    continue
                }
                guard case .attachment(let ref) = part else { continue }
                media.request(ref)
                let want = HomeMapping.attachment(ref, picture: media.asset(ref.hash), progress: Self.shownProgress(item, ref))
                let have = message.parts.lazy.compactMap { p -> Attachment? in
                    if case let .attachment(a) = p, a.id == ref.hash { return a }
                    return nil
                }.first
                if let have, have != want { controller.dispatch(.cmuxSetAttachment(id, want)) }
            }
        }
    }

    /// A link preview's picture, fetched by its hash like an attachment's
    /// (never the URL): once ready it fills a card that has none
    /// (`.linkMetadata`, the card redraws in place).
    private func refreshLinkPicture(_ link: LinkPreview, in message: Message) {
        guard let image = link.image else { return }
        media.request(HomeMapping.attachmentRef(image))
        guard let picture = media.asset(image.hash) else { return }
        let bare = message.parts.contains { part in
            if case let .link(url, _, _, shown, _) = part { return url == link.url && shown == nil }
            return false
        }
        if bare { controller.dispatch(.linkMetadata(url: link.url, title: nil, site: nil, image: picture)) }
    }

    /// MessagesLab draws upload progress only on file rows (a bar); image and
    /// video bubbles show none. Steps of 2%, so a fast upload redraws its
    /// row at most 50 times.
    static func shownProgress(_ item: TranscriptItem, _ ref: AttachmentRef) -> Double? {
        guard let p = item.attachmentProgress[ref.hash], !["image", "video"].contains(HomeMapping.kind(of: ref)) else { return nil }
        return (p * 50).rounded(.down) / 50
    }

    private func item(_ message: ID) -> TranscriptItem? {
        shown.first { HomeMapping.id($0, aliases: aliases) == message }
    }

    /// The HomeStore root of the thread a send from the view at `ref` replies in:
    /// `.some(nil)` with no view open; nil when the root has no message id yet. A reply
    /// names its own root (its root may be out of the window or retracted, so the
    /// view's ref can be the reply itself).
    private func threadRoot(of ref: PartRef?) -> MessageID?? {
        guard let ref else { return .some(nil) }
        let found = item(ref.messageId)
            ?? homeStore.transcript(for: conversation).first { HomeMapping.id($0, aliases: aliases) == ref.messageId }
        return found.flatMap { $0.threadRoot ?? $0.messageID }.map { Optional.some($0) }
    }

    /// ThreadMode.tree: the HomeStore message a send from the open view answers, the drilled
    /// branch's message (MessagesLab's `.send` makes it the local reply's `parent`, ThreadHost.swift):
    /// `.some(nil)` for the root (no branch open); nil when that message has no message id yet
    /// (my send still going), so the reply is never moved to another parent.
    private func treeParent(of state: AppState) -> MessageID?? {
        guard state.ui.threadMode == .tree, let open = state.ui.openThread else { return .some(nil) }
        guard let branch = state.ui.threadPath.last else {
            // A view opened at a reply whose root is not loaded (MessagesLab takes the reply as the
            // root): the send answers that reply.
            let shownRoot = item(open.messageId)
            guard let shownRoot, let mid = shownRoot.messageID, shownRoot.threadRoot != nil, shownRoot.threadRoot != mid else { return .some(nil) }
            return .some(mid)
        }
        let found = item(branch.messageId)
            ?? homeStore.transcript(for: conversation).first { HomeMapping.id($0, aliases: aliases) == branch.messageId }
        // A retracted branch message takes no reply (the owner refuses part 0 of it): refused here, never re-parented.
        guard let found, !found.isRetracted else { return nil }
        return found.messageID.map { Optional.some($0) }
    }

    func pickAttachments() { onPickAttachments() }
    func takeAttachments(from pasteboard: NSPasteboard) -> Bool { onAttachmentPasteboard(pasteboard) }
    func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool { acceptsAttachmentDrag(pasteboard) }
    func attachmentPasteText(from pasteboard: NSPasteboard) -> String? { onAttachmentPasteText(pasteboard) }
    /// A draft attachment's file under its own name (the store's copy is named by hash), linked
    /// once into HomeMedia's folder: Copy of the box's selection puts it on the pasteboard.
    func draftAttachmentFile(_ id: ID) -> URL? {
        guard let local = drafts[id] else { return nil }
        let opener = HomeAttachmentOpen(folder: HomeMedia.directory)
        return (try? opener.namedCopy(of: local.fileURL, name: local.ref.name, hash: local.ref.hash)) ?? local.fileURL
    }
    func takeDroppedAttachments(from pasteboard: NSPasteboard) -> Bool { (onAttachmentDrop ?? onAttachmentPasteboard)(pasteboard) }
    func acceptsDroppedAttachments(from pasteboard: NSPasteboard) -> Bool { (acceptsAttachmentDrop ?? acceptsAttachmentDrag)(pasteboard) }
    func attachmentDropTargeted(_ targeted: Bool) { onAttachmentDropTarget(targeted) }
    func statusLineClicked(_ rect: CGRect, in view: NSView) {
        let popover = turnPopover ?? {
            let made = HomeTurnStatusPopover { [weak self] in self?.liveLine.details() }
            // Closed by Esc or a click outside: the field takes the keyboard back (a click elsewhere keeps its own).
            made.onClosed = { [weak self] in
                guard let self, let window = view.window else { return }
                // A click that closed it in another text field keeps that field's keyboard.
                if let other = window.firstResponder as? NSText, other !== self.controller.demo?.compose.textView.view { return }
                self.controller.focusCompose()
            }
            turnPopover = made
            return made
        }()
        popover.toggle(relativeTo: rect, of: view)
    }

    func draftChanged() {
        if sendNotice == CmuxStrings.threadRootNotReady { sendNotice = nil }  // the user moved on
        // The text with its marks, and the attachments (Delete or a cut can take a chip with the text).
        saveDraft()
        // My typing dots for the other members (HomeStore+Typing); off once the field is empty.
        homeStore.composing(controller.store?.state.ui.draft.plainText ?? "", in: conversation)
        onDraftTextChange()
    }

    /// The field's text from the last launch or the last view of this chat (HomeStore's cache,
    /// home-state-ownership.md section 4), once, into an empty field, without its marks: each
    /// attachment goes back at its mark when it is ready (`restoreDraftAttachments(into:)`).
    private func restoreDraft(_ kept: String?) {
        guard let store = controller.store, store.state.ui.draft.text.isEmpty else { return }
        let text = Draft.stripMarks(kept ?? "")
        guard !text.isEmpty else { return }
        controller.dispatch(.setDraft(text))
    }

    /// A received card fetches its preview only after a tap (HomeLinkPreviews, through LinkGuard).
    func linkTapped(_ ref: PartRef, url: String) {
        guard let linkPreviews, !stopped else { return }
        linkPreviews.allowTap(url)
        linkPreviews.fetch(url) { [weak self] meta in
            guard let self, !self.stopped, let meta else { return }
            self.controller.dispatch(.linkMetadata(url: url, title: meta.title, site: meta.site, image: meta.image))
        }
    }

    /// lane 16's rule (HomeController.cancellableSend): my pending send while
    /// it uploads, or a failed one.
    func canCancelSend(_ message: ID) -> Bool {
        guard let item = item(message), item.seq == nil, item.author == me else { return false }
        switch item.delivery {
        case .notDelivered: return true
        case .sending: return !item.attachmentProgress.isEmpty
        case .committed: return false
        }
    }

    func cancelSend(_ message: ID) {
        guard canCancelSend(message), let item = item(message) else { return }
        _ = onCancelSend(item.key)
    }

    func toggleVideo(_ ref: PartRef, _ attachment: ID) {
        guard let attachmentRef = attachmentRef(ref.messageId, attachment) else { return }
        video.toggle(ref, attachment: attachmentRef, source: media)
    }

    func videoState(_ ref: PartRef) -> HomeVideoState { video.state(ref) }

    private func attachmentRef(_ message: ID, _ attachment: ID) -> AttachmentRef? {
        item(message)?.parts.lazy.compactMap { p -> AttachmentRef? in
            if case .attachment(let r) = p, r.hash == attachment { return r }
            return nil
        }.first
    }

    func openAttachment(_ message: ID, _ attachment: ID) {
        // cmux: the host's file host opens it in cmux beside Home (never Finder); else the
        // host's path-link opener; without a host it goes to the system as before.
        let fileHost = controller.fileHost, appLink = controller.onAppLink
        let reveal = attachmentRef(message, attachment).map { HomeAttachmentPolicy.revealsInsteadOfOpening(name: $0.name) } ?? false
        // task-owner: one fetch; ends when the file opens
        Task { [weak self] in
            guard let self, let url = await self.attachmentFile(message, attachment) else { return }
            if fileHost == nil, appLink == nil, reveal || HomeAttachmentPolicy.revealsInsteadOfOpening(name: url.lastPathComponent) {
                // Without a host, a received script, installer or HTML page is shown in Finder, never run.
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
            HomeAttachmentOpen.open(url, host: fileHost, appLink: appLink)
        }
    }

    func attachmentFile(_ message: ID, _ attachment: ID) async -> URL? {
        guard let ref = attachmentRef(message, attachment), let blob = try? await media.original(ref) else { return nil }
        let name = ref.name, hash = ref.hash
        let opener = HomeAttachmentOpen(folder: HomeMedia.directory)
        // The store names its copy by hash; the viewer and Open With read the attachment's name.
        return await Task.detached(priority: .userInitiated) {
            (try? opener.namedCopy(of: blob, name: name, hash: hash)) ?? blob
        }.value
    }

    /// Test seams for the alias table.
    func rememberAlias(_ key: IdempotencyKey, _ id: ID) { core.aliases[key] = id }

    func react(_ ref: PartRef, _ kind: Reaction.Kind) {
        guard isSendEnabled, let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }),
              let message = item.messageID else { return }
        if case let .emoji(e) = kind { RecentEmoji.use(e) }  // MessagesLab 02519e9: recent emoji lead the menu and strip
        // A split text (Messages' link rule) is one HomeStore part.
        let partIndex = HomeMapping.homeIndex(ref.partIndex, HomeMapping.projectedParts(item, summary: shownSummary).owners)
        let intent = HomeIntent(op: .addReaction(message: message, conversation: conversation,
                                                 reaction: HomeMapping.kind(kind), partIndex: partIndex))
        let homeStore = self.homeStore
        // task-owner: one op; ends with the owner's answer
        Task { [weak self] in
            do {
                _ = try await homeStore.perform(intent.op, key: intent.key)
            } catch let rejection as HomeRejection {
                guard let self, !self.stopped else { return }
                self.onRefusal(intent, rejection)
            } catch {}
        }
    }

    func rowsPlaced() {
        video.place()
    }

    func scrolled() {
        video.place()
        if let previews = linkPreviews?.previews {
            // My link cards that scrolled in with no title (also from HomeStore): a cached title,
            // else the guarded parser.
            if let urls = controller.demo?.visibleUntitledOutgoingLinks(), !urls.isEmpty { previews.consider(urls) }
        }
        askForOlderIfNeeded()
        reportReadIfNeeded()
    }

    /// Once per page: the oldest loaded row is within a screen of the
    /// viewport (also when the rows do not fill it).
    private func askForOlderIfNeeded() {
        guard hasOlder, !olderRequested, !stopped, let demo = controller.demo else { return }
        let g = demo.windowGeometry
        guard g.distanceToTop < g.viewport else { return }
        olderRequested = true
        let homeStore = self.homeStore, id = conversation
        let oldest = homeStore.oldestLoadedSeq(in: id)
        // task-owner: one page read; ends with its reply
        Task { [weak self] in
            await homeStore.loadOlder(id)
            // A read that brought nothing (it failed, its page no longer joined the
            // window, another read was running) ends the ask, so the next scroll asks
            // again; otherwise the transcript stopped at its oldest loaded message
            // (Lawrence 2026-10-20, "I can't scroll up further, it's stuck").
            guard let self, !self.stopped, homeStore.oldestLoadedSeq(in: id) == oldest else { return }
            self.olderRequested = false
        }
    }

    /// Advances my read cursor to the newest committed message while the
    /// newest row is on screen and the user can see it.
    private func reportReadIfNeeded() {
        guard isVisibleToUser, !stopped, let store = controller.store, store.state.ui.scroll.pinnedToBottom,
              let newest = shown.last(where: { $0.seq != nil })?.seq else { return }
        let cursor = max(reportedRead, shownSummary?.readCursors[me] ?? 0)
        guard newest > cursor else { return }
        reportedRead = newest
        let homeStore = self.homeStore
        let op = HomeOp.setReadCursor(conversation: conversation, seq: newest)
        // task-owner: one op; ends with the owner's answer
        Task { try? await homeStore.perform(op) }
    }
}

/// The adapter's model: what HomeStore last said, and this view's sends in
/// flight. Shared by `HomeProjection` (the live view) and the differential
/// harness (a virtual clock), so both turn HomeStore snapshots into the same
/// MessagesLab actions.
struct ProjectionCore {
    let me: ParticipantID
    private(set) var shown: [TranscriptItem] = []
    private(set) var summary: ConversationSummary?
    /// HomeStore key of a send this view started -> its reducer id.
    var aliases: [IdempotencyKey: ID] = [:]
    /// Bubble pictures by content hash (`HomeMedia.asset`).
    var media: HomeMapping.Media = { _ in nil }
    /// Link previews already fetched (`LinkPreviews.cached`); none in the harness.
    var links: HomeMapping.Links = { _ in nil }
    /// Chosen sender avatars by participant id (`setAvatars`).
    private(set) var avatars: [String: Participant.Avatar] = [:]
    private var installed = false
    /// The running replies on screen, in begin order (`streams(_:state:)`, MessagesLab ask 11).
    var shownStreams: [ShownStream] = []
    /// Whole messages (default) or the growing stream bubbles (`HomeReplyDisplay`).
    var replies: HomeReplyDisplay = .wholeMessages
    /// Each running reply's parts between tokens, by turn (a cache: copies of the core share it).
    let streamMappers = HomeStreamMappers()

    init(me: ParticipantID) { self.me = me }

    /// The projection store's first conversation and window place.
    mutating func install(_ id: ConversationID, items: [TranscriptItem], summary: ConversationSummary?)
        -> (Conversation, (start: Int, total: Int)) {
        shown = items
        shownStreams = [] // a new projection store has no stream: the next update begins them again
        self.summary = summary
        installed = true
        let roots = HomeMapping.roots(in: items, aliases: aliases, summary: summary, media: media, links: links)
        let conv = Conversation(id: id.rawValue, title: HomeMapping.title(summary, me: me),
                                participants: HomeMapping.participants(summary, me: me, avatars: avatars),
                                messages: items.map { HomeMapping.message($0, aliases: aliases, me: me, summary: summary, media: media, links: links, roots: roots) },
                                cmuxGroup: summary?.showsSenderNames(me: me) == true)
        return (conv, HomeMapping.window(items))
    }

    /// New chosen avatars by participant id (the host's Chief avatars, again after a swap): the
    /// action that redraws the senders with them; nil when they are the ones shown, or before the
    /// install (which maps them).
    mutating func setAvatars(_ new: [String: Participant.Avatar]) -> Action? {
        guard new != avatars else { return nil }
        avatars = new
        return installed ? .cmuxSetParticipants(HomeMapping.participants(summary, me: me, avatars: new)) : nil
    }

    /// The actions from the shown snapshot to this one.
    mutating func step(items: [TranscriptItem], summary new: ConversationSummary?) -> HomeDiff {
        // The shown snapshot again (a streamed token, typing, the activity line): nothing to diff.
        // Mapping every row again cost 3.5 ms per token at 60 rows on the main thread, which a
        // drag over the field waits for (DragWhileStreamingTests).
        if items == shown, new == summary { return HomeDiff() }
        let d = HomeDiff.plan(old: shown, new: items, oldSummary: summary, newSummary: new, aliases: aliases, me: me, media: media, links: links,
                              handOff: streamingTurns)
        shown = items
        summary = new
        return d
    }

    /// Typing changes after the step's actions were dispatched.
    func typing(_ state: AppState, wanted: Set<ParticipantID>) -> [Action] {
        HomeDiff.typing(current: state.ui.typing, wanted: wanted, me: me)
    }

    /// After `.send` was dispatched: the local message stands for `key`.
    mutating func recordSend(_ key: IdempotencyKey, in state: AppState) -> Bool {
        guard let local = state.conversation.messages.last, local.senderId == me.rawValue else { return false }
        aliases[key] = local.id
        return true
    }

    mutating func forget(_ key: IdempotencyKey) { aliases[key] = nil }
}
