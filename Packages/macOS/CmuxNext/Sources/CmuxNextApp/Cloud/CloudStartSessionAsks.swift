import CmuxNextActions
import CmuxNextAgentPane
import Foundation

/// An agent's ask to start a Cloud session, as a card in its own chat (``AgentToolCards``): the
/// agent's run waits for the person's Start or Not now, for at most ``wait``. The ask owns its
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

    /// Shows the card in chat tab `tab` and returns its token once the person clicks Start. Throws
    /// when they choose Not now, when nobody answers within ``wait``, or when the chat has no page.
    func ask(tab: String, text: String, services: AppServices) async throws -> UUID {
        guard open[tab] == nil else { throw ActionFailure(message: CloudStartSessionStrings.askOpen) }
        let token = UUID()
        let (answers, continuation) = AsyncStream<Bool?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let actions = [AgentPaneToolCard.Action(id: "start", title: CloudStartSessionStrings.start),
                       AgentPaneToolCard.Action(id: "notNow", title: CloudMoveAskStrings.notNow)]
        guard set([card(tab, .ask, text, actions)], tab: tab, services: services, answer: { _, action, _ in continuation.yield(action == "start") }) else {
            continuation.finish()
            _ = set([], tab: tab, services: services) { _, _, _ in }
            throw ActionFailure(message: CloudStartSessionStrings.noPage)
        }
        open[tab] = token
        // task-owner: the card's one-shot deadline; cancelled below once the person answers.
        let deadline = Task {
            // wakeup-allow: one-shot deadline for the person's answer on the card
            try? await Task.sleep(for: Self.wait)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        var answer: Bool?
        for await value in answers {
            answer = value
            break
        }
        guard answer == true else {
            finish(tab: tab, token: token, failure: nil, services: services)
            throw ActionFailure(message: answer == false ? CloudStartSessionStrings.declined : CloudStartSessionStrings.expired)
        }
        return token
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

    private func card(_ tab: String, _ state: AgentPaneToolCard.State, _ text: String, _ actions: [AgentPaneToolCard.Action]) -> AgentPaneToolCard {
        AgentPaneToolCard(id: "cloud-start-session-" + tab, state: state, text: text, actions: actions)
    }

    private func set(_ cards: [AgentPaneToolCard], tab: String, services: AppServices, answer: @escaping AgentToolCards.Answer) -> Bool {
        if let present { return present(cards, tab, services, answer) }
        return services.cloud.toolCards.set(cards, owner: Self.owner, tab: tab, answer: answer)
    }
}

/// `cmux cloud start-session` runs by what they ask for: the same ask again while one runs joins
/// it, and the next same ask after a run that outlasted its caller's answer (the caller got
/// `pending`) gets that run's end, once. A run its caller saw end is not kept. Ended runs are kept at most ``kept`` long and at most ``limit`` of them, pruned when
/// a run starts; no timer.
@MainActor
final class CloudStartSessionRuns {
    struct Key: Hashable {
        var machine: String
        var agent: String
        var cwd: String?
        /// The agent chat that asked; nil for a person's or a script's run.
        var caller: String?

        init(_ request: CloudStartSession.Request, caller: String?) {
            machine = request.machineID.map { "id:" + $0 } ?? "name:" + (request.name ?? "")
            agent = request.agent
            cwd = request.cwd
            self.caller = caller
        }
    }

    typealias Fields = [String: ActionResultValue]

    private struct Run {
        var task: Task<Fields, any Error>
        var ended: ContinuousClock.Instant?
    }

    static let kept: Duration = .seconds(600)
    static let limit = 32
    private var runs: [Key: Run] = [:]
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// The run of `key`: one already running or ended (an ended one is handed out once), else
    /// `work`, started now. `answeredWithin`: how long the caller waits before it answers
    /// `pending`; a run that ends sooner reached its caller and is not kept.
    func join(_ key: Key, answeredWithin: Duration, _ work: @escaping @MainActor () async throws -> Fields) async throws -> Fields {
        if let run = runs[key] {
            if run.ended != nil { runs[key] = nil }
            return try await run.task.value
        }
        prune()
        // task-owner: the start itself; it runs to its end even after its caller answered pending.
        let task = Task<Fields, any Error> { @MainActor in try await work() }
        runs[key] = Run(task: task)
        let started = now()
        defer {
            if runs[key]?.task == task {
                // A margin under the caller's own wait: an end that close may have lost the race.
                if now() - started < answeredWithin - .seconds(2) { runs[key] = nil } else { runs[key]?.ended = now() }
            }
        }
        return try await task.value
    }

    var count: Int { runs.count }

    private func prune() {
        let cutoff = now() - Self.kept
        runs = runs.filter { $0.value.ended.map { $0 > cutoff } ?? true }
        let ended = runs.filter { $0.value.ended != nil }.sorted { $0.value.ended! < $1.value.ended! }
        for (key, _) in ended.prefix(max(0, runs.count - Self.limit + 1)) { runs[key] = nil }
    }
}
