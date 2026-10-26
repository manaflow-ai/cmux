import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCompat
import Foundation

/// An agent's ask to start a Cloud session, as a card in its own chat (``AgentToolCards``): the
/// agent's run waits for the person's Start or Not now, for at most ``wait``, and while the
/// account it was asked in stays signed in (a sign-out or team switch ends the card). The ask owns its
/// chat's card from the ask until its run ends (``finish(tab:token:failure:services:)``): another
/// ask in that chat meanwhile is refused, and never replaces it.
@MainActor
final class CloudStartSessionAsks {
    static let owner = "cloudStartSession"
    /// How long a card waits for the person; the run says so after.
    static let wait: Duration = .seconds(120)
    /// The ask that owns each chat's card, by tab.
    private(set) var open: [String: UUID] = [:]
    /// Shows `cards` in chat tab `tab` (none removes them), each click going to the answer; false
    /// when the chat has no page. The app's tool cards by default; a test's own.
    var present: (@MainActor (_ cards: [AgentPaneToolCard], _ tab: String, _ services: AppServices, _ answer: @escaping AgentToolCards.Answer) -> Bool)?

    enum Answer: Sendable { case start, notNow, expired, accountChanged }

    /// Shows the card in chat tab `tab` and returns its token once the person clicks Start. Throws
    /// when they choose Not now, when nobody answers within ``wait``, when the signed-in account
    /// stops being `account` (`now`, read on every change), or when the chat has no page.
    func ask(tab: String, text: String, asked: CloudStartSessionStrings.Asked, account: [String?],
             now: @escaping @MainActor @Sendable () -> [String?], services: AppServices) async throws -> UUID {
        guard open[tab] == nil else { throw ActionFailure(message: CloudStartSessionStrings.askOpen(asked)) }
        let token = UUID()
        let (answers, continuation) = AsyncStream<Answer>.makeStream(bufferingPolicy: .bufferingOldest(1))
        guard set([Self.askCard(tab: tab, text: text)], tab: tab, services: services, answer: { _, action, _ in continuation.yield(action == "start" ? .start : .notNow) }) else {
            continuation.finish()
            _ = set([], tab: tab, services: services) { _, _, _ in }
            throw ActionFailure(message: CloudStartSessionStrings.noPage(asked))
        }
        open[tab] = token
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
        }
        var answer = Answer.expired
        for await value in answers {
            answer = value
            break
        }
        switch answer {
        case .start:
            return token
        case .notNow, .expired, .accountChanged:
            finish(tab: tab, token: token, failure: nil, services: services)
            let message = switch answer {
            case .notNow: CloudStartSessionStrings.declined(asked)
            case .accountChanged: CloudStartSessionStrings.accountChanged(asked)
            default: CloudStartSessionStrings.expired(asked)
            }
            throw ActionFailure(message: message)
        }
    }

    /// The card while its run goes on; only the ask that owns it changes it.
    func show(tab: String, token: UUID, _ state: AgentPaneToolCard.State, _ text: String, services: AppServices) {
        guard open[tab] == token else { return }
        _ = set([card(tab, state, text, [])], tab: tab, services: services) { _, _, _ in }
    }

    /// The run ended: the card goes, or says why it stopped with Dismiss; the chat may ask again.
    func finish(tab: String, token: UUID, failure: String?, services: AppServices) {
        guard open[tab] == token else { return }
        open[tab] = nil
        guard let failure else { return _ = set([], tab: tab, services: services) { _, _, _ in } }
        let dismiss = AgentPaneToolCard.Action(id: "dismiss", title: CloudMoveAskStrings.dismiss)
        _ = set([card(tab, .failed, failure, [dismiss])], tab: tab, services: services) { [weak self, weak services] _, _, _ in
            // A later ask in this chat owns the card from then on; its Dismiss is its own.
            guard let self, let services, open[tab] == nil else { return }
            _ = set([], tab: tab, services: services) { _, _, _ in }
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

    private func set(_ cards: [AgentPaneToolCard], tab: String, services: AppServices, answer: @escaping AgentToolCards.Answer) -> Bool {
        if let present { return present(cards, tab, services, answer) }
        return services.cloud.toolCards.set(cards, owner: Self.owner, tab: tab, answer: answer)
    }
}

/// `cmux cloud start-session` runs by what they ask for. Each caller waits for its run at most
/// its answer time, then answers `pending`, and the run goes on. The same ask again while a run
/// goes on waits for that run. A run that ends with a caller still waiting has reached it and is
/// dropped; one that ends after every caller answered `pending` is kept for the next same ask,
/// which gets its end once. A kept run lasts at most ``kept`` (checked on every ask) and at most
/// ``limit`` are kept, trimmed when a run starts and when one is kept; no timer. Runs and
/// creations are per account (user and team): another account's ask never joins or takes them,
/// and a sign-out or account change forgets them (``forgetAll()``).
@MainActor
final class CloudStartSessionRuns {
    struct Key: Hashable {
        var machine: String
        var agent: String
        var cwd: String?
        /// The agent chat that asked; nil for a person's or a script's run.
        var caller: String?
        /// The user and team signed in when it was asked (``CloudService/account``).
        var account: [String?]

        init(_ request: CloudStartSession.Request, caller: String?, account: [String?]) {
            machine = request.machineID.map { "id:" + $0 } ?? "name:" + (request.name ?? "")
            agent = request.agent
            cwd = request.cwd
            self.caller = caller
            self.account = account
        }
    }

    private struct Creation: Hashable {
        var name: String
        var account: [String?]
    }

    typealias Fields = [String: ActionResultValue]
    typealias Outcome = Result<Fields, any Error>

    private final class Run {
        var task: Task<Outcome, Never>?
        /// Callers waiting for its end now, each resumed when it ends, or removed at its own deadline.
        var waiters: [UUID: AsyncStream<Outcome?>.Continuation] = [:]
        var waiting: Int { waiters.count }
        var outcome: Outcome?
        /// When it ended with nobody waiting (kept for the next same ask).
        var kept: ContinuousClock.Instant?
    }

    static let kept: Duration = .seconds(600)
    static let limit = 32
    private var runs: [Key: Run] = [:]
    /// Creations of a machine by name and account: two asks for one new name create one machine.
    private var creations: [Creation: Task<CloudMachineSession, any Error>] = [:]
    /// Called when an ask joins a creation already going on (tests wait on it).
    var joinedCreation: @MainActor (String) -> Void = { _ in }

    /// The machine `create` makes for `name` in `account`, or the one a creation already going on
    /// for both makes.
    func creating(_ name: String, account: [String?], _ create: @escaping @MainActor () async throws -> CloudMachineSession) async throws -> CloudMachineSession {
        let key = Creation(name: name, account: account)
        if let running = creations[key] {
            joinedCreation(name)
            return try await running.value
        }
        // task-owner: one creation per name and account; removed when it ends or by forgetAll().
        let task = Task<CloudMachineSession, any Error> { @MainActor in try await create() }
        creations[key] = task
        defer { if creations[key] == task { creations[key] = nil } }
        return try await task.value
    }

    /// Forgets every run and creation: the account they were asked in ended. Runs going on are
    /// cancelled; their callers get their end (a cancellation) or have already answered pending.
    func forgetAll() {
        for run in runs.values { run.task?.cancel() }
        for creation in creations.values { creation.cancel() }
        runs = [:]
        creations = [:]
    }
    var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// The caller's wait: a one-shot sleep, cancelled when the run ends first.
    var sleep: @MainActor (Duration) async -> Void = { duration in
        // wakeup-allow: one-shot answer deadline of one caller; cancelled when its run ends first
        try? await Task.sleep(for: duration)
    }

    /// The end of `key`'s run, or `pending` once `within` has passed (the run goes on): a kept
    /// run's end (handed out once), the one going on, else `work`, started now.
    func answer(_ key: Key, within: Duration, pending: Fields, _ work: @escaping @MainActor () async throws -> Fields) async throws -> Fields {
        let run = take(key, work)
        if let outcome = run.outcome { return try outcome.get() }
        let caller = UUID()
        let (ends, continuation) = AsyncStream<Outcome?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // The run's end resumes it (``take``); nothing else waits on the run for this caller.
        run.waiters[caller] = continuation
        // task-owner: this caller's answer deadline; cancelled below once the run ends first.
        let deadline = Task { @MainActor [sleep] in
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
        // An end that came as the deadline did still reaches this caller.
        if let outcome = ended ?? run.outcome { return try outcome.get() }
        return pending
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
            for waiter in run.waiters.values { waiter.yield(outcome) }
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

    /// Drops expired kept runs, then the oldest kept ones beyond `keeping`.
    private func trim(keeping: Int) {
        let cutoff = now() - Self.kept
        runs = runs.filter { $0.value.kept.map { $0 > cutoff } ?? true }
        let kept = runs.compactMap { key, run in run.kept.map { (key, $0) } }.sorted { $0.1 < $1.1 }
        for (key, _) in kept.prefix(max(0, kept.count - keeping)) { runs[key] = nil }
    }

    /// Before a new run: room for it among the kept ones.
    private func prune() { trim(keeping: Self.limit - 1) }

    var keptCount: Int { runs.values.filter { $0.kept != nil }.count }
    /// Callers waiting on any run now (tests: a caller that answered pending holds nothing).
    var waitingCount: Int { runs.values.reduce(0) { $0 + $1.waiting } }
}
