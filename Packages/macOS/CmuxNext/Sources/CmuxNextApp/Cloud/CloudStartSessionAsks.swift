import CmuxNextActions
import CmuxNextAgentPane
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
        /// The ask's wait for the person's answer; nil once they clicked Start.
        var answer: AsyncStream<Answer>.Continuation?
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

    /// Shows the card in chat tab `tab` and returns its token once the person clicks Start. Throws
    /// when they choose Not now, when nobody answers within ``wait``, when the signed-in account
    /// stops being `account` (`now`, read on every change), or when the chat has no page; throws
    /// `CancellationError` when the run is cancelled. Every way out but Start removes the card.
    func ask(tab: String, text: String, asked: CloudStartSessionStrings.Asked, account: [String?],
             now: @escaping @MainActor @Sendable () -> [String?]) async throws -> UUID {
        guard open[tab] == nil else { throw ActionFailure(message: CloudStartSessionStrings.askOpen(asked)) }
        let token = UUID()
        let (answers, continuation) = AsyncStream<Answer>.makeStream(bufferingPolicy: .bufferingOldest(1))
        guard set([Self.askCard(tab: tab, text: text)], tab: tab, answer: { _, action, _ in continuation.yield(action == "start" ? .start : .notNow) }) else {
            continuation.finish()
            _ = set([], tab: tab) { _, _, _ in }
            throw ActionFailure(message: CloudStartSessionStrings.noPage(asked))
        }
        open[tab] = Open(token: token, asked: asked, answer: continuation)
        linked.remove(tab)
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

/// `cmux cloud start-session` runs by what they ask for. Each caller waits for its run at most
/// its answer time, then answers `pending`, and the run goes on. The same ask again while a run
/// goes on waits for that run. A run that ends with a caller still waiting has reached it and is
/// dropped; one that ends after every caller answered `pending` is kept for the next same ask,
/// which gets its end once. A kept run lasts at most ``kept`` (checked on every ask) and at most
/// ``limit`` are kept, trimmed when a run starts and when one is kept; no timer. Runs and
/// creations are per account (user and team): another account's ask never joins or takes them,
/// and a sign-out or team switch ends them (``forgetAll()``).
@MainActor
final class CloudStartSessionRuns {
    struct Key: Hashable {
        /// `id:<machine id>` or `name:<machine name>`.
        var machine: String
        var agent: String
        var cwd: String?
        /// The agent chat that asked; nil for a person's or a script's run.
        var caller: String?
        /// The user and team signed in when it was asked (``CloudService/account``).
        var account: [String?]
    }

    private struct Creation: Hashable {
        var name: String
        var account: [String?]
    }

    typealias Fields = [String: ActionResultValue]
    typealias Outcome = Result<Fields, any Error>

    private final class Run {
        var task: Task<Outcome, Never>?
        /// Callers waiting for its end now: each is resumed when it ends, with the failure it
        /// gets if the run is forgotten first, or removes itself at its own deadline.
        var waiters: [UUID: (end: AsyncStream<Outcome?>.Continuation, forgotten: any Error)] = [:]
        var outcome: Outcome?
        /// Forgotten (``forgetAll()``): a caller whose deadline fired first gets its `forgotten`
        /// failure all the same, never `pending`.
        var forgotten = false
        /// When it ended with nobody waiting (kept for the next same ask).
        var kept: ContinuousClock.Instant?
    }

    static let kept: Duration = .seconds(600)
    static let limit = 32
    private var runs: [Key: Run] = [:]
    /// Creations of a machine by name and account, each with its own token: two asks for one new
    /// name create one machine.
    private var creations: [Creation: (token: UUID, task: Task<CloudMachineSession, any Error>)] = [:]
    /// Counts ``forgetAll()`` calls: a creation that ends after one is never handed out.
    private var forgets = 0
    /// Called when an ask joins a creation already going on (tests wait on it).
    var joinedCreation: @MainActor (String) -> Void = { _ in }
    var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// The caller's wait: a one-shot sleep, cancelled when the run ends first.
    var sleep: @MainActor (Duration) async -> Void = { duration in
        // wakeup-allow: one-shot answer deadline of one caller; cancelled when its run ends first
        try? await Task.sleep(for: duration)
    }

    /// The machine `create` makes for `name` in `account`, or the one a creation already going on
    /// for both makes. A creation the runs were forgotten during (``forgetAll()``) throws
    /// `CancellationError` even if it finished: cancellation is cooperative.
    func creating(_ name: String, account: [String?], _ create: @escaping @MainActor () async throws -> CloudMachineSession) async throws -> CloudMachineSession {
        let key = Creation(name: name, account: account)
        let asked = forgets
        let unforgotten = { [self] (machine: CloudMachineSession) throws -> CloudMachineSession in
            guard forgets == asked else { throw CancellationError() }
            return machine
        }
        if let running = creations[key] {
            joinedCreation(name)
            return try unforgotten(await running.task.value)
        }
        let token = UUID()
        // task-owner: one creation per name and account; removed when it ends or by forgetAll().
        let task = Task<CloudMachineSession, any Error> { @MainActor in try await create() }
        creations[key] = (token, task)
        defer { if creations[key]?.token == token { creations[key] = nil } }
        return try unforgotten(await task.value)
    }

    /// The end of `key`'s run, or `pending` once `within` has passed (the run goes on): a kept
    /// run's end (handed out once), the one going on, else `work`, started now. If the runs are
    /// forgotten while this caller waits (``forgetAll()``), it gets `forgotten`.
    func answer(_ key: Key, within: Duration, pending: Fields, forgotten: any Error,
                _ work: @escaping @MainActor () async throws -> Fields) async throws -> Fields {
        let run = take(key, work)
        if let outcome = run.outcome { return try outcome.get() }
        let caller = UUID()
        let (ends, continuation) = AsyncStream<Outcome?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // The run's end resumes it (``take``), or ``forgetAll()``; nothing else waits on the run.
        run.waiters[caller] = (continuation, forgotten)
        // task-owner: this caller's answer deadline; cancelled below once the run ends first.
        let deadline = Task { @MainActor [sleep] in
            // wakeup-allow: one-shot answer deadline of one caller; cancelled when its run ends first
            await sleep(within)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            run.waiters[caller] = nil
            continuation.finish()
        }
        var ended: Outcome?
        for await value in ends {
            ended = value
            break
        }
        if let ended { return try ended.get() }
        // The stream keeps the first value: a forget or an end that came after the deadline did,
        // before this caller resumed, is read from the run. The forget wins (the run was cancelled);
        // an end reaches the caller instead of pending, and the run counts as seen (``take`` drops
        // it, since this caller was still registered when it ended).
        if run.forgotten { throw forgotten }
        if let outcome = run.outcome { return try outcome.get() }
        return pending
    }

    /// The account the runs were asked in ended: each waiting caller gets its `forgotten`
    /// failure now, every run and creation is cancelled, and none is kept or joined after.
    func forgetAll() {
        forgets += 1
        for run in runs.values {
            run.forgotten = true
            for waiter in run.waiters.values { waiter.end.yield(.failure(waiter.forgotten)) }
            run.waiters = [:]
            run.task?.cancel()
        }
        for creation in creations.values { creation.task.cancel() }
        runs = [:]
        creations = [:]
    }

    /// The run of `key` to answer: a kept one (taken out, its end handed out once), the one going
    /// on, else a new one.
    private func take(_ key: Key, _ work: @escaping @MainActor () async throws -> Fields) -> Run {
        if let run = runs[key] {
            if let kept = run.kept {
                runs[key] = nil
                if now() - kept <= Self.kept { return run }
            } else {
                return run
            }
        }
        prune()
        let run = Run()
        runs[key] = run
        // task-owner: the start itself; it runs to its end even after its callers answered pending.
        run.task = Task { @MainActor [weak self] in
            let outcome: Outcome
            do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
            run.outcome = outcome
            let reached = !run.waiters.isEmpty
            for waiter in run.waiters.values { waiter.end.yield(outcome) }
            if let self, runs[key] === run {
                if reached {
                    runs[key] = nil
                } else {
                    run.kept = now()
                    trim(keeping: Self.limit)
                }
            }
            return outcome
        }
        return run
    }

    /// Waits for `key`'s run to end (tests).
    func settled(_ key: Key) async { _ = await runs[key]?.task?.value }

    var count: Int { runs.count }
    var keptCount: Int { runs.values.filter { $0.kept != nil }.count }
    /// Callers waiting on any run now (tests: a caller that answered pending holds nothing).
    var waitingCount: Int { runs.values.reduce(0) { $0 + $1.waiters.count } }

    /// Drops expired kept runs, then the oldest kept ones beyond `keeping`.
    private func trim(keeping: Int) {
        let cutoff = now() - Self.kept
        runs = runs.filter { $0.value.kept.map { $0 > cutoff } ?? true }
        let kept = runs.compactMap { key, run in run.kept.map { (key, $0) } }.sorted { $0.1 < $1.1 }
        for (key, _) in kept.prefix(max(0, kept.count - keeping)) { runs[key] = nil }
    }

    /// Before a new run: room for it among the kept ones.
    private func prune() { trim(keeping: Self.limit - 1) }
}
