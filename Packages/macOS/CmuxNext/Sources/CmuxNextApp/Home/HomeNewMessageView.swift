import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine

/// New Message as a page, as in Messages (Lawrence 2026-10-19: "it makes a
/// modal but iMessage just creates a new page"): the To: field across the
/// top, and under it either the conversation the chosen people already
/// have (its history at once, its own message box) or a blank page with
/// Home's message box. The first send there makes the DM or group (one
/// person: `dm.open`; several: a group, a132's model through
/// `HomeService.startConversation`; addresses only: the email-link start,
/// which carries the message) and posts the text; the page then hands the
/// conversation to the Home page (`onSent`). What was typed stays while the
/// person looks at another conversation: the page keeps its state.
@MainActor
final class HomeNewMessageView: NSView {
    let field = HomeRecipientField()
    /// Clips the conversation below the field (its header slides under the field).
    let content = HomeNewMessageClip()
    let notice = ThemedLabel(wrappingLabelWithString: "")
    /// The conversation the chosen people already have, shown under the field.
    private(set) var existing: ConversationID?
    private(set) var host: HomeHostView?
    /// The blank page's message box, over a store that only knows the draft.
    private(set) var composer: HomeNativeTranscriptView?
    private var composerStore: HomeStore?
    private var spellCheckingWatch: Task<Void, Never>?
    private weak var services: AppServices?
    /// The first send made this conversation (the Home page shows it).
    var onSent: (ConversationID) -> Void = { _ in }
    /// Escape with nothing chosen or typed: the page ends the draft.
    var onEscape: () -> Void = {}
    private var stopped = false

    init(services: AppServices) {
        self.services = services
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.home.newMessage")
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        addSubview(content)
        addSubview(field)
        notice.font = Typography.caption
        notice.themeColor = { Palette.danger }
        notice.isHidden = true
        notice.setAccessibilityIdentifier("cmux.home.newMessage.notice")
        addSubview(notice)
        addSubview(field.suggestions)
        let home = services.home
        field.contacts = { [weak home] in home?.contacts() ?? [] }
        // Before anyone is chosen the list under To: offers the Chiefs (plans/cmux-next/chief-group-chats-DESIGN.md).
        field.idleSuggestions = { [weak home, weak field] in field.flatMap { home?.newMessageChiefs($0.draft) } ?? [] }
        field.suggestions.look = { [weak home] in home?.recipientLook($0) ?? HomeRecipientLook() }
        // The list's New Chief and Invite rows run the same actions as the Home menu and the palette.
        field.onNewChief = { [weak services] in _ = services?.registry.perform("home.newChief", invocation: ActionInvocation(origin: .user)) }
        field.onInvite = { [weak services] in _ = services?.registry.perform("home.invite", invocation: ActionInvocation(origin: .user)) }
        // A typed email address offers Invite to Team under it: the action's confirmation dialog, prefilled.
        field.inviteTeam = { [weak services] in
            guard let cloud = services?.cloud, cloud.isSignedIn else { return nil }
            return cloud.auth.activeTeam.team?.displayName
        }
        field.onInviteToTeam = { [weak services] address in
            _ = services?.registry.perform("home.inviteToTeam",
                                           invocation: ActionInvocation(arguments: ["email": .string(address.description)], origin: .user))
        }
        field.onChange = { [weak self] _ in self?.recipientsChanged() }
        field.onDone = { [weak self] in self?.focusMessageBox() }
        field.onEscape = { [weak self] in
            guard let self, isEmpty else { return }
            onEscape()
        }
        showComposer(carrying: "")
        spellCheckingWatch = Task { [weak self, weak services] in
            for await enabled in ObservationStream({ services?.settings?.snapshot.agentPaneComposer.spellChecking ?? false }) {
                self?.composer?.composerSpellCheckingEnabled = enabled
            }
        }
        field.refreshSuggestions()
        // task-owner: one read of the team and Chiefs for the suggestions; ends when it is read
        Task { [weak self] in
            await home.directory.refresh()
            self?.field.refreshSuggestions()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // The last reference can go on any thread (OffMainReleaseCleanupTests' shape, 39256ad7181). This view owns no
    // Sendable handle; its composer's own HomeStore is main-actor and only stop() ends its connection, resend and
    // prune tasks and flushes its cache, so the stops run on the main actor. A guard that returned off main
    // skipped them, and the store ran on.
    nonisolated deinit {
        let composer = composer, composerStore = composerStore
        spellCheckingWatch?.cancel()
        // task-owner: the main-actor half of this view's release; one call each, then it ends
        Task { @MainActor in
            composer?.stop()
            composerStore?.stop()
        }
    }

    /// Nothing chosen, nothing typed in To:, and an empty message box:
    /// leaving drops the draft (and its row in the list).
    var isEmpty: Bool { field.draft.isEmpty && messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The message box's text (the blank page's, or the shown conversation's draft).
    var messageText: String {
        if let existing { return services?.home.homeStore.draft(for: existing) ?? "" }
        return composerStore?.draft(for: HomeNewMessageComposerSource.conversation) ?? ""
    }

    /// Where the keyboard goes when the page shows: To: until someone is
    /// chosen, then the message box (a draft the person comes back to).
    var focusTarget: NSView { field.draft.recipients.isEmpty ? field.primaryInput : messageBox ?? field.primaryInput }

    private var messageBox: NSView? { host?.focusTarget ?? composer?.primaryInput }

    func focusRecipients() { window?.makeFirstResponder(field.primaryInput) }

    /// A key typed while Home had the keyboard outside a text input: the
    /// page's input takes the keyboard (caret at the end, nothing selected)
    /// and the key.
    func beginTyping(with event: NSEvent) {
        let target = focusTarget
        guard let window, window.makeFirstResponder(target) else { return }
        if let editor = (target as? NSTextField)?.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        window.firstResponder?.keyDown(with: event)
    }

    func focusMessageBox() {
        guard let box = messageBox else { return }
        window?.makeFirstResponder(box)
    }

    /// Ends the page's store and views (the draft was sent or dropped). Once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        composer?.stop()
        composerStore?.stop()
    }

    // MARK: Recipients

    /// The chosen people changed: show their conversation when they have
    /// one, else the blank page; the typed text moves with the message box.
    private func recipientsChanged() {
        say(nil)
        guard let services else { return }
        let home = services.home
        let match = field.draft.existingConversation(in: home.homeStore.rows, me: home.homeStore.me?.id)
        guard match != existing else { needsLayout = true; return }
        let text = messageText
        if let existing { home.homeStore.setDraft("", for: existing) }
        if let match {
            showConversation(match, carrying: text)
        } else {
            showComposer(carrying: text)
        }
        needsLayout = true
    }

    private func showConversation(_ id: ConversationID, carrying text: String) {
        guard let services else { return }
        removeComposer()
        host?.removeFromSuperview()
        let store = services.home.homeStore
        if !text.isEmpty, (store.draft(for: id) ?? "").isEmpty { store.setDraft(text, for: id) }
        let view = HomeHostView(services: services, conversation: id.rawValue)
        content.addSubview(view)
        host = view
        existing = id
    }

    private func showComposer(carrying text: String) {
        guard let services else { return }
        host?.removeFromSuperview()
        host = nil
        existing = nil
        if let composerStore {
            composerStore.setDraft(text, for: HomeNewMessageComposerSource.conversation)
            composer.map { content.addSubview($0) }
            return
        }
        let me = services.home.homeStore.me ?? services.home.homeSource.me
        let source = HomeNewMessageComposerSource(me: me) { [weak self] parts in
            guard let self else { throw HomeRejection.invalid("new_message.closed") }
            return try await firstSend(parts)
        }
        let store = HomeStore(source: source)
        store.start()
        if !text.isEmpty { store.setDraft(text, for: HomeNewMessageComposerSource.conversation) }
        let view = HomeNativeTranscriptView(store: store, conversation: HomeNewMessageComposerSource.conversation, me: me.id,
                                            openPanel: services.openPanel)
        view.composerSpellCheckingEnabled = services.settings?.snapshot.agentPaneComposer.spellChecking ?? false
        // The first message is text: attachments go once the conversation exists (they upload to it).
        view.attachmentPreparer = nil
        view.setAccessibilityIdentifier("cmux.home.newMessage.composer")
        content.addSubview(view)
        composer = view
        composerStore = store
    }

    private func removeComposer() { composer?.removeFromSuperview() }

    // MARK: First send

    /// The blank page's Return: makes the conversation, posts `parts` there,
    /// and hands it to the Home page. A refusal says why under the field
    /// and gives the text back to the message box (the draft store's send
    /// path restores it).
    func firstSend(_ parts: [MessagePart]) async throws -> HomeOpResult {
        let draft = field.draft
        if let blocker = draft.sendBlocker {
            say(blocker)
            focusRecipients()
            throw HomeRejection.invalid("new_message.recipients")
        }
        guard let services else { throw HomeRejection.invalid("new_message.closed") }
        let home = services.home
        let addressesOnly = draft.recipients.allSatisfy { if case .address = $0 { true } else { false } }
        let outcome = await home.startConversation(draft.recipients, title: "", firstMessage: addressesOnly ? parts : [])
        switch outcome {
        case .opened(let id):
            if !addressesOnly {
                // The real store owns the send from here (its offline queue and Not Delivered state).
                _ = try? await home.homeStore.perform(.sendMessage(conversation: id, parts: parts))
            }
            onSent(id)
            return HomeOpResult(rev: 0, conversation: id)
        case .invited(let id):
            if let id { onSent(id) }
            return HomeOpResult(rev: 0, conversation: id)
        default:
            say(outcome.message ?? HomeNewMessageDraft.needsRecipientNotice)
            throw HomeRejection.invalid("new_message.refused")
        }
    }

    /// The line under the field (a refusal), or nil to hide it.
    func say(_ text: String?) {
        notice.stringValue = text ?? ""
        notice.isHidden = text == nil
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let fieldHeight = field.height(forWidth: width)
        field.frame = NSRect(x: 0, y: 0, width: width, height: fieldHeight)
        var top = fieldHeight
        if !notice.isHidden {
            let height = ceil(notice.size(forWidth: width - 28).height)
            notice.frame = NSRect(x: 14, y: top + 6, width: width - 28, height: height)
            top += height + 12
        }
        content.frame = NSRect(x: 0, y: top, width: width, height: max(0, bounds.height - top))
        // The conversation's own header (name, avatar) sits under the To: field, as in Messages.
        let header = host?.headerHeight ?? composer?.headerHeight ?? 0
        let inner = NSRect(x: 0, y: -header, width: width, height: content.bounds.height + header)
        for view in [host as NSView?, composer as NSView?].compactMap({ $0 }) where view.frame != inner { view.frame = inner }
        let suggestions = field.suggestions
        // Under the refusal line when it shows, so the Chiefs listed before anyone is chosen never hide it.
        let listTop = notice.isHidden ? fieldHeight + 2 : notice.frame.maxY + 6
        let height = min(suggestions.preferredHeight, max(0, bounds.height - listTop - 18))
        suggestions.frame = NSRect(x: 10, y: listTop, width: max(0, width - 20), height: height)
    }
}

/// The page's content area: flipped, so the conversation's header can sit
/// above its top edge, and clipped, so it never draws over the To: field.
final class HomeNewMessageClip: NSView {
    nonisolated override var isFlipped: Bool { true }
}
