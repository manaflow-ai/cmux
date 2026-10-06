import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Observation

/// The adapter between HomeStore (the single writer of the transcript,
/// plans/cmux-next/home-mac.md section 2) and the vendored MessagesLab
/// controller. HomeStore snapshots become MessagesLab actions on the
/// projection store (`HomeDiff`); the user's sends and tapbacks become
/// `HomeIntent`s with their idempotency keys. The projection never decides
/// what is in the transcript; it only animates what HomeStore says.
///
/// A send: the draft goes to `HomeStore.perform(.sendMessage)` with a fresh
/// key, and `.send` is dispatched on the projection in the same turn, so the
/// morph flies at the press as in MessagesLab. The local message keeps its
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
    /// False while the owner is unreachable (H17: Send and tapbacks off).
    var isSendEnabled = true
    /// The host's notice, shown as a row of the transcript (nil: none).
    var notice: String?
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
    /// While dragging, types only.
    var acceptsAttachmentDrag: (NSPasteboard) -> Bool = { _ in false }
    /// The store refused a send's attachment before logging it; the draft is back.
    var onAttachmentRefusal: (HomeAttachmentError) -> Void = { _ in }
    /// The field's text changed.
    var onDraftTextChange: () -> Void = {}
    /// Cancel Upload (`HomeStoreBinding.cancelSend`).
    var onCancelSend: (IdempotencyKey) -> Bool = { _ in false }
    /// Bubble pictures and originals.
    let media = HomeMedia()
    /// Inline video playback in the bubbles.
    let video = HomeVideo()
    /// Prepared attachments in the field by content hash (the chips are
    /// MessagesLab's draft; a removed chip's entry is ignored).
    private var drafts: [String: LocalAttachment] = [:]

    /// What the projection shows, as HomeStore said it (shared with the harness).
    private(set) var core: ProjectionCore
    var shown: [TranscriptItem] { core.shown }
    var shownSummary: ConversationSummary? { core.summary }
    var aliases: [IdempotencyKey: ID] { core.aliases }
    private(set) var hasOlder = false
    private var olderRequested = false
    private var reportedRead: Seq = 0
    private var stopped = false
    /// Rebuilds and applied (changed) updates, for tests.
    private(set) var rebuilds = 0
    private(set) var appliedUpdates = 0

    /// Link card previews (LinkPresentation, MessagesLab's LinkPreviews): fetched
    /// once per URL for links this Mac sends or the user taps; nil keeps domain cards.
    let linkPreviews: HomeLinkPreviews?

    init(store: HomeStore, conversation: ConversationID, me: ParticipantID, controller: ChatController,
         linkPreviews: HomeLinkPreviews? = nil) {
        homeStore = store
        self.linkPreviews = linkPreviews
        self.conversation = conversation
        self.me = me
        self.controller = controller
        core = ProjectionCore(me: me)
        let media = self.media
        core.media = { [unowned media] in media.asset($0) }
        if let linkPreviews { core.links = { [unowned linkPreviews] in linkPreviews.cached($0) } }
        controller.intents = self
        video.controller = controller
        media.onReady = { [weak self] _ in self?.refreshAttachments() }
    }

    func start() {
        refresh()
        observe()
    }

    func stop() {
        stopped = true
        controller.intents = nil
    }

    // MARK: HomeStore -> projection

    private func refresh() {
        apply(items: homeStore.transcript(for: conversation), summary: homeStore.summary(conversation),
              typing: homeStore.typing[conversation] ?? [], hasOlder: homeStore.hasOlderMessages(in: conversation))
    }

    /// One update per store change (Observation, no polling), as HomeStoreBinding does.
    private func observe() {
        guard !stopped else { return }
        let id = conversation
        withObservationTracking {
            _ = homeStore.transcriptVersion[id]
            _ = homeStore.typing[id]
            _ = homeStore.rows
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    /// The whole current value; unchanged values return before any work.
    func apply(items: [TranscriptItem], summary: ConversationSummary?, typing: Set<ParticipantID>, hasOlder newHasOlder: Bool) {
        if controller.store == nil {
            install(items: items, summary: summary, typing: typing, hasOlder: newHasOlder)
            restoreDraft()
            return
        }
        let typingChanged = Set(controller.store.state.ui.typing) != Set(typing.filter { $0 != me }.map(\.rawValue))
        guard items != shown || summary != shownSummary || typingChanged || newHasOlder != hasOlder else { return }
        appliedUpdates += 1
        if newHasOlder != hasOlder { olderRequested = false }
        hasOlder = newHasOlder
        let titleChanged = HomeMapping.title(summary, me: me) != HomeMapping.title(shownSummary, me: me)
        let summaryChanged = summary != shownSummary
        let diff = core.step(items: items, summary: summary)
        if diff.rebuild {
            rebuild()
        } else {
            for a in diff.actions {
                if case .prependPage = a { olderRequested = false }
                controller.dispatch(a)
            }
        }
        for a in core.typing(controller.store.state, wanted: typing) { controller.dispatch(a) }
        if titleChanged { applyHeader() }
        refreshAttachments()
        video.place()
        if summaryChanged { onSummaryChange(summary) }
        onRowsChange()
        askForOlderIfNeeded()
        reportReadIfNeeded()
    }

    private func install(items: [TranscriptItem], summary: ConversationSummary?, typing: Set<ParticipantID>, hasOlder: Bool) {
        let (conv, w) = core.install(conversation, items: items, summary: summary)
        self.hasOlder = hasOlder
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.store.linkPreviews = linkPreviews
        if let previews = linkPreviews?.previews {
            // MessagesLab 85684b4: the LinkPresentation fallback runs only for an OUTGOING card on
            // screen (a link I sent); a late answer fills the card.
            previews.isOnScreen = { [weak self] url in self?.controller.demo?.outgoingLinkOnScreen(url) ?? false }
            previews.onLateMetadata = { [weak self] url, meta in
                guard let self, !self.stopped else { return }
                self.controller.dispatch(.linkMetadata(url: url, title: meta.title, site: meta.site, image: meta.image))
            }
        }
        applyHeader()
        for a in core.typing(controller.store.state, wanted: typing) { controller.dispatch(a) }
        refreshAttachments()
        onSummaryChange(summary)
        onRowsChange()
    }

    /// The whole window again, without animation (MessagesLab has no action
    /// for it): `.replaceWindow`, then the pin or the first visible row's
    /// window position is restored.
    private func rebuild() {
        guard let demo = controller.demo else { return }
        rebuilds += 1
        let pinned = controller.store.state.ui.scroll.pinnedToBottom
        let anchor = demo.anchorProbe
        let msgs = shown.map { HomeMapping.message($0, aliases: aliases, me: me, summary: shownSummary, media: core.media, links: core.links) }
        let pendingLocal = controller.store.state.conversation.messages.filter { m in
            aliases.contains { $0.value == m.id } && !msgs.contains { $0.id == m.id }
        }
        controller.dispatch(.replaceWindow(msgs + pendingLocal, start: HomeMapping.window(shown, summary: shownSummary).start))
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

    private func applyHeader() {
        controller.host.paneHeader.title = HomeMapping.title(shownSummary, me: me)
        controller.host.paneHeader.initials = initialsOverride ?? HomeMapping.initials(shownSummary, me: me)
    }

    // MARK: Projection -> HomeStore (intents)

    var canReact: Bool { isSendEnabled }
    /// HomeOp has no reply (no reply_to on message.send, no thread
    /// rendering from HomeStore): swipe-to-reply stays off.
    var canReply: Bool { false }

    func send() {
        guard isSendEnabled, homeStore.isOnline, let store = controller.store else { return }
        let draft = store.state.ui.draft
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draft.attachments.compactMap { drafts[$0.id] }
        guard !text.isEmpty || !attachments.isEmpty, store.state.atNewest else { return }
        let key = IdempotencyKey.make()
        linkPreviews?.allowSend(text)
        controller.dispatch(.send)
        homeStore.setDraft("", for: conversation)
        guard core.recordSend(key, in: controller.store.state) else { return }
        for a in attachments {
            media.useLocal(a.files, for: a.ref.hash)
            drafts[a.ref.hash] = nil
        }
        let homeStore = self.homeStore, conversation = self.conversation
        // task-owner: one send; ends with the owner's answer
        Task { [weak self] in
            do {
                if attachments.isEmpty {
                    _ = try await homeStore.perform(.sendMessage(conversation: conversation, parts: [.text(text)]), key: key)
                } else {
                    try await homeStore.send(conversation: conversation, text: text, attachments: attachments, key: key)
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
    }

    /// Refused before it reached the log (offline, nothing queues, or an
    /// attachment the owner would refuse): the local message goes and the
    /// text and attachments return. A logged refusal stays as "Not
    /// Delivered" (HomeStore's item).
    func sendRefused(_ key: IdempotencyKey, text: String, attachments: [LocalAttachment] = [], _ rejection: HomeRejection? = nil,
                     notice: HomeAttachmentError? = nil) {
        guard !stopped, !homeStore.transcript(for: conversation).contains(where: { $0.key == key }) else { return }
        core.forget(key)
        rebuild()
        if controller.store.state.ui.draft.text.isEmpty, !text.isEmpty { controller.dispatch(.setDraft(text)) }
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

    private func restoreDraft(_ attachment: LocalAttachment) {
        let hash = attachment.ref.hash
        guard !stopped, let store = controller.store, !store.state.ui.draft.attachments.contains(where: { $0.id == hash }) else { return }
        drafts[hash] = attachment
        controller.dispatch(.attach(HomeMapping.attachment(attachment.ref, picture: media.asset(hash), progress: nil)))
    }

    /// The field's attachments, in order.
    var draftAttachments: [LocalAttachment] {
        (controller.store?.state.ui.draft.attachments ?? []).compactMap { drafts[$0.id] }
    }

    func removeDraft(_ hash: String) {
        drafts[hash] = nil
        controller.dispatch(.removeDraftAttachment(hash))
    }

    /// Each shown attachment part gets its picture and upload state:
    /// HomeStore's progress and HomeMedia's pictures change no transcript
    /// content, so they reach MessagesLab's message without a transition
    /// (`.cmuxSetAttachment`, the row redraws in place).
    func refreshAttachments() {
        guard !stopped, let store = controller.store else { return }
        for item in shown where !item.isRetracted && !item.attachmentHashes.isEmpty {
            for (hash, files) in item.localAttachments { media.useLocal(files, for: hash) }
            let id = HomeMapping.id(item, aliases: aliases)
            guard let message = store.state.message(id) else { continue }
            for part in item.parts {
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

    func pickAttachments() { onPickAttachments() }
    func takeAttachments(from pasteboard: NSPasteboard) -> Bool { onAttachmentPasteboard(pasteboard) }
    func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool { acceptsAttachmentDrag(pasteboard) }
    func draftChanged() {
        homeStore.setDraft(controller.store?.state.ui.draft.text ?? "", for: conversation)
        onDraftTextChange()
    }

    /// The field's text from the last launch (HomeStore's cache,
    /// home-state-ownership.md section 4), once, into an empty field.
    private func restoreDraft() {
        guard let store = controller.store, store.state.ui.draft.text.isEmpty,
              let text = homeStore.draft(for: conversation), !text.isEmpty else { return }
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
        guard let ref = item(message)?.parts.lazy.compactMap({ p -> AttachmentRef? in
            if case .attachment(let r) = p, r.hash == attachment { return r }
            return nil
        }).first else { return }
        let media = self.media
        // task-owner: one fetch; ends when the file opens
        Task { if let url = try? await media.original(ref) { NSWorkspace.shared.open(url) } }
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

    func scrolled() {
        video.place()
        if let previews = linkPreviews?.previews {
            // My link cards that scrolled in with no title (also from HomeStore): a cached title, else the fallback.
            if let urls = controller.demo?.visibleUntitledOutgoingLinks(), !urls.isEmpty { previews.consider(urls) }
            previews.visibilityChanged()
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
        // task-owner: one page read; ends with its reply
        Task { await homeStore.loadOlder(id) }
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

    init(me: ParticipantID) { self.me = me }

    /// The projection store's first conversation and window place.
    mutating func install(_ id: ConversationID, items: [TranscriptItem], summary: ConversationSummary?)
        -> (Conversation, (start: Int, total: Int)) {
        shown = items
        self.summary = summary
        let conv = Conversation(id: id.rawValue, title: HomeMapping.title(summary, me: me),
                                participants: HomeMapping.participants(summary, me: me),
                                messages: items.map { HomeMapping.message($0, aliases: aliases, me: me, summary: summary, media: media, links: links) })
        return (conv, HomeMapping.window(items, summary: summary))
    }

    /// The actions from the shown snapshot to this one.
    mutating func step(items: [TranscriptItem], summary new: ConversationSummary?) -> HomeDiff {
        let d = HomeDiff.plan(old: shown, new: items, oldSummary: summary, newSummary: new, aliases: aliases, me: me, media: media, links: links)
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
