import AppKit
import CmuxHomeCore
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
    /// The window is key and visible: the read cursor may advance.
    var isVisibleToUser = false { didSet { if isVisibleToUser { reportReadIfNeeded() } } }
    var onSummaryChange: (ConversationSummary?) -> Void = { _ in }
    var onRowsChange: () -> Void = {}
    /// A refused tapback (a refused send restores its draft instead).
    var onRefusal: (HomeIntent, HomeRejection) -> Void = { _, _ in }
    /// Lane 16 seam: the attachment intake.
    var onAttach: () -> Void = {}

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

    init(store: HomeStore, conversation: ConversationID, me: ParticipantID, controller: ChatController) {
        homeStore = store
        self.conversation = conversation
        self.me = me
        self.controller = controller
        core = ProjectionCore(me: me)
        controller.intents = self
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
        if summaryChanged { onSummaryChange(summary) }
        onRowsChange()
        askForOlderIfNeeded()
        reportReadIfNeeded()
    }

    private func install(items: [TranscriptItem], summary: ConversationSummary?, typing: Set<ParticipantID>, hasOlder: Bool) {
        let (conv, w) = core.install(conversation, items: items, summary: summary)
        self.hasOlder = hasOlder
        controller.install(conv, windowStart: w.start, total: w.total)
        applyHeader()
        for a in core.typing(controller.store.state, wanted: typing) { controller.dispatch(a) }
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
        let msgs = shown.map { HomeMapping.message($0, aliases: aliases, me: me, summary: shownSummary) }
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

    private func applyHeader() {
        controller.host.paneHeader.title = HomeMapping.title(shownSummary, me: me)
        controller.host.paneHeader.initials = HomeMapping.initials(shownSummary, me: me)
    }

    // MARK: Projection -> HomeStore (intents)

    var canReact: Bool { isSendEnabled }

    func send() {
        guard isSendEnabled, homeStore.isOnline, let store = controller.store else { return }
        let text = store.state.ui.draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.state.atNewest else { return }
        let key = IdempotencyKey.make()
        controller.dispatch(.send)
        guard core.recordSend(key, in: controller.store.state) else { return }
        let op = HomeOp.sendMessage(conversation: conversation, parts: [.text(text)])
        let homeStore = self.homeStore
        // task-owner: one op; ends with the owner's answer
        Task { [weak self] in
            do {
                _ = try await homeStore.perform(op, key: key)
            } catch let rejection as HomeRejection {
                self?.sendRefused(key, text: text, rejection)
            } catch {
                // HomeSendState.pendingResend: the store resends with the same key.
            }
        }
    }

    /// Refused before it reached the log (offline, nothing queues): the
    /// local message goes and the text returns. A logged refusal stays as
    /// "Not Delivered" (HomeStore's item).
    func sendRefused(_ key: IdempotencyKey, text: String, _ rejection: HomeRejection) {
        guard !stopped, !homeStore.transcript(for: conversation).contains(where: { $0.key == key }) else { return }
        core.forget(key)
        rebuild()
        if controller.store.state.ui.draft.text.isEmpty { controller.dispatch(.setDraft(text)) }
    }

    /// Test seams for the alias table.
    func rememberAlias(_ key: IdempotencyKey, _ id: ID) { core.aliases[key] = id }

    func react(_ ref: PartRef, _ kind: Reaction.Kind) {
        guard isSendEnabled, let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }),
              let message = item.messageID else { return }
        let intent = HomeIntent(op: .addReaction(message: message, conversation: conversation,
                                                 reaction: HomeMapping.kind(kind), partIndex: ref.partIndex))
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

    func attach() { onAttach() }

    func scrolled() {
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

    init(me: ParticipantID) { self.me = me }

    /// The projection store's first conversation and window place.
    mutating func install(_ id: ConversationID, items: [TranscriptItem], summary: ConversationSummary?)
        -> (Conversation, (start: Int, total: Int)) {
        shown = items
        self.summary = summary
        let conv = Conversation(id: id.rawValue, title: HomeMapping.title(summary, me: me),
                                participants: HomeMapping.participants(summary, me: me),
                                messages: items.map { HomeMapping.message($0, aliases: aliases, me: me, summary: summary) })
        return (conv, HomeMapping.window(items, summary: summary))
    }

    /// The actions from the shown snapshot to this one.
    mutating func step(items: [TranscriptItem], summary new: ConversationSummary?) -> HomeDiff {
        let d = HomeDiff.plan(old: shown, new: items, oldSummary: summary, newSummary: new, aliases: aliases, me: me)
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
