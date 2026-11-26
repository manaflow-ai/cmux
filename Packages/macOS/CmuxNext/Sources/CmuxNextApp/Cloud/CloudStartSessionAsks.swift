import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCompat
import Foundation

/// An agent's ask to start a Cloud session, as a card in its own chat (``AgentToolCards``): the
/// agent's run waits for the person's Start or Not now, for at most ``wait``, and while the
/// account it was asked in stays signed in. The ask owns its chat's card from the ask until its
/// run ends (``finish(tab:token:failure:)``): another ask in that chat meanwhile is refused, and
/// never replaces it. A sign-out or team switch ends every card (``endAll()``).
@MainActor
final class CloudStartSessionAsks {
    static let owner = "cloudStartSession"
    /// How long a card waits for the person; the run says so after.
    static let wait: Duration = .seconds(120)

    enum Answer: Sendable { case start, notNow, expired, accountChanged }

    private struct Open {
        var token: UUID
        var asked: CloudStartSessionStrings.Asked
        /// The ask as `cmux agents dialog list` names it (``dialogID(_:)``).
        var dialog: String
        /// The card's text, and the agent session of the chat that asked (nil: unknown).
        var text: String
        var caller: String?
        /// The ask's wait for the person's answer; nil once they clicked Start.
        var answer: AsyncStream<Answer>.Continuation?
        /// The person answered (the card or ``answer(dialog:start:)``): a later answer is not taken.
        var answered = false
        /// Its account ended (``endAll()``) while it asked: a Start already sent is void.
        var ended = false
    }

    /// The ask that owns each chat's card, by tab.
    private var open: [String: Open] = [:]
    /// Chats whose card links to a started session (``started(tab:token:text:gone:reveal:)``),
    /// removed by ``endAll()`` with the account they were started in.
    private var linked: Set<String> = []
    /// Where cards show: the app's tool cards (set by ``CloudService``), or a test's ``present``.
    weak var toolCards: AgentToolCards?
    /// Shows `cards` in chat tab `tab` (none removes them), each click going to the answer; false
    /// when the chat has no page. Set by tests in place of the app's tool cards.
    var present: (@MainActor (_ cards: [AgentPaneToolCard], _ tab: String, _ answer: @escaping AgentToolCards.Answer) -> Bool)?

    /// The ask that owns chat tab `tab`'s card, if any.
    func owner(of tab: String) -> UUID? { open[tab]?.token }

    /// An ask's id in `cmux agents dialog list|answer`: its token, so a later ask in the same chat
    /// is another dialog and an answer to an ended one finds nothing.
    static func dialogID(_ token: UUID) -> String { "cloud-start-" + token.uuidString.lowercased() }

    /// An ask still waiting for the person's answer, as `cmux agents dialog list` shows it.
    struct Waiting: Equatable {
        var dialog: String
        var tab: String
        var text: String
        var caller: String?
        var asked: CloudStartSessionStrings.Asked
    }

    /// The asks still waiting for an answer (their card asks), oldest chat first by tab id.
    var waiting: [Waiting] {
        open.compactMap { tab, ask in
            ask.answer == nil || ask.answered ? nil : Waiting(dialog: ask.dialog, tab: tab, text: ask.text, caller: ask.caller, asked: ask.asked)
        }.sorted { $0.tab < $1.tab }
    }

    /// Answers the waiting ask `dialog` as the card's Start (`start`) or Not now would; false when no
    /// ask waits under that id (answered, ended, or never one). Who may answer is the caller's check
    /// (``CloudAskDialogs``): this only delivers it.
    func answer(dialog: String, start: Bool) -> Bool {
        guard let tab = open.first(where: { $0.value.dialog == dialog })?.key else { return false }
        return deliver(tab: tab, dialog: dialog, start ? .start : .notNow)
    }

    /// The person's one answer to the ask `dialog` in chat `tab`, from the card or the CLI; false
    /// when that ask no longer waits or was answered already.
    private func deliver(tab: String, dialog: String, _ value: Answer) -> Bool {
        guard let ask = open[tab], ask.dialog == dialog, !ask.answered, let answer = ask.answer else { return false }
        open[tab]?.answered = true
        answer.yield(value)
        return true
    }

    /// Shows the card in chat tab `tab` and returns its token once the person clicks Start. Throws
    /// when they choose Not now, when nobody answers within ``wait``, when the signed-in account
    /// stops being `account` (`now`, read on every change), or when the chat has no page; throws
    /// `CancellationError` when the run is cancelled. Every way out but Start removes the card.
    /// `caller`: the asking chat's agent session; `shown` gets the ask's dialog id once its card shows.
    func ask(tab: String, text: String, asked: CloudStartSessionStrings.Asked, account: [String?],
             now: @escaping @MainActor @Sendable () -> [String?], caller: String? = nil,
             shown: @MainActor (String) -> Void = { _ in }) async throws -> UUID {
        guard open[tab] == nil else { throw ActionFailure(message: CloudStartSessionStrings.askOpen(asked)) }
        let token = UUID()
        let (answers, continuation) = AsyncStream<Answer>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let dialog = Self.dialogID(token)
        guard set([Self.askCard(tab: tab, text: text)], tab: tab, answer: { [weak self] _, action, _ in
            _ = self?.deliver(tab: tab, dialog: dialog, action == "start" ? .start : .notNow)
        }) else {
            continuation.finish()
            _ = set([], tab: tab) { _, _, _ in }
            throw ActionFailure(message: CloudStartSessionStrings.noPage(asked))
        }
        open[tab] = Open(token: token, asked: asked, dialog: dialog, text: text, caller: caller, answer: continuation)
        linked.remove(tab)
        shown(dialog)
        // task-owner: the card's one-shot deadline; cancelled below once the person answers.
        let deadline = Task {
            // wakeup-allow: one-shot deadline for the person's answer on the card
            try? await Task.sleep(for: Self.wait)
            continuation.yield(.expired)
        }
        // task-owner: the card's watch on the signed-in account; cancelled below with the card.
        let watch = Task { @MainActor in
            for await signedIn in ObservationStream(now) where signedIn != account {
                continuation.yield(.accountChanged)
                return
            }
        }
        defer {
            deadline.cancel()
            watch.cancel()
            continuation.finish()
            if open[tab]?.token == token { open[tab]?.answer = nil }
        }
        var answer: Answer?
        for await value in answers {
            answer = value
            break
        }
        guard var answer else {
            // The run was cancelled (its account ended, ``CloudStartSessionRuns/forgetAll()``).
            finish(tab: tab, token: token, failure: nil)
            throw CancellationError()
        }
        // A Start that came before the account ended, with this ask not yet resumed: the stream
        // keeps the first answer, so the end is read from the ask and the account itself.
        if case .start = answer, open[tab]?.token != token || open[tab]?.ended == true || now() != account { answer = .accountChanged }
        switch answer {
        case .start:
            return token
        case .notNow, .expired, .accountChanged:
            finish(tab: tab, token: token, failure: nil)
            let message = switch answer {
            case .notNow: CloudStartSessionStrings.declined(asked)
            case .accountChanged: CloudStartSessionStrings.accountChanged(asked)
            default: CloudStartSessionStrings.expired(asked)
            }
            throw ActionFailure(message: message)
        }
    }

    /// The card while its run goes on; only the ask that owns it changes it.
    func show(tab: String, token: UUID, _ state: AgentPaneToolCard.State, _ text: String) {
        guard open[tab]?.token == token else { return }
        _ = set([card(tab, state, text, [])], tab: tab) { _, _, _ in }
    }

    /// The run ended: the card goes, or says why it stopped with Dismiss; the chat may ask again.
    func finish(tab: String, token: UUID, failure: String?) {
        guard open[tab]?.token == token else { return }
        open[tab] = nil
        guard let failure else { return _ = set([], tab: tab) { _, _, _ in } }
        let dismiss = AgentPaneToolCard.Action(id: "dismiss", title: CloudMoveAskStrings.dismiss)
        _ = set([card(tab, .failed, failure, [dismiss])], tab: tab) { [weak self] _, _, _ in
            // A later ask in this chat owns the card from then on; its Dismiss is its own.
            guard let self, open[tab] == nil else { return }
            _ = set([], tab: tab) { _, _, _ in }
        }
    }

    /// The run ended with the session started: the card says where, with Open Chat and Dismiss, so
    /// the asking chat links to the new chat on the machine; the chat may ask again. Open Chat calls
    /// `reveal`, which shows the new chat and answers false when no connected machine lists it any
    /// more: the card then says `gone`, with Dismiss.
    func started(tab: String, token: UUID, text: String, gone: String, reveal: @escaping @MainActor () -> Bool) {
        guard open[tab]?.token == token else { return }
        open[tab] = nil
        linked.insert(tab)
        let actions = [AgentPaneToolCard.Action(id: "open", title: CloudStartSessionStrings.openChat),
                       AgentPaneToolCard.Action(id: "dismiss", title: CloudMoveAskStrings.dismiss)]
        _ = set([card(tab, .done, text, actions)], tab: tab) { [weak self] _, action, _ in
            // A later ask in this chat owns the card from then on; its buttons are its own.
            guard let self, open[tab] == nil else { return }
            linked.remove(tab)
            guard action == "open" else { return _ = set([], tab: tab) { _, _, _ in } }
            if reveal() { return _ = set([], tab: tab) { _, _, _ in } }
            let dismiss = AgentPaneToolCard.Action(id: "dismiss", title: CloudMoveAskStrings.dismiss)
            _ = set([card(tab, .failed, gone, [dismiss])], tab: tab) { [weak self] _, _, _ in
                guard let self, open[tab] == nil else { return }
                _ = set([], tab: tab) { _, _, _ in }
            }
        }
    }

    /// The account the asks were made in ended: a card still asking ends its ask (which removes
    /// it), one whose run goes on says the run stopped, and a done card goes. Called by ``CloudService`` on a
    /// sign-out or team switch, beside ``CloudStartSessionRuns/forgetAll()``.
    func endAll() {
        // A done card's Open Chat would show a chat of the account that ended.
        for tab in linked where open[tab] == nil { _ = set([], tab: tab) { _, _, _ in } }
        linked = []
        // A snapshot: ``finish`` removes entries as it goes.
        for (tab, ask) in Array(open) {
            if let answer = ask.answer {
                open[tab]?.ended = true
                answer.yield(.accountChanged)
            } else {
                finish(tab: tab, token: ask.token, failure: CloudStartSessionStrings.accountChangedWhileStarting(ask.asked))
            }
        }
    }

    /// The card that asks: the agent's ask in `text`, with Start and Not now.
    static func askCard(tab: String, text: String) -> AgentPaneToolCard {
        let actions = [AgentPaneToolCard.Action(id: "start", title: CloudStartSessionStrings.start),
                       AgentPaneToolCard.Action(id: "notNow", title: CloudMoveAskStrings.notNow)]
        return AgentPaneToolCard(id: "cloud-start-session-" + tab, state: .ask, text: text, actions: actions)
    }

    private func card(_ tab: String, _ state: AgentPaneToolCard.State, _ text: String, _ actions: [AgentPaneToolCard.Action]) -> AgentPaneToolCard {
        AgentPaneToolCard(id: "cloud-start-session-" + tab, state: state, text: text, actions: actions)
    }

    private func set(_ cards: [AgentPaneToolCard], tab: String, answer: @escaping AgentToolCards.Answer) -> Bool {
        if let present { return present(cards, tab, answer) }
        return toolCards?.set(cards, owner: Self.owner, tab: tab, answer: answer) ?? false
    }
}

/// `cmux cloud start-session` runs (``CloudStartRuns``, CmuxNextCloud) with this App's answer and machines.
typealias CloudStartSessionRuns = CloudStartRuns<[String: ActionResultValue], CloudMachineSession>
