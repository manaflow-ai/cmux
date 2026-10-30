public import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
import CryptoKit
public import Foundation
import Observation

/// The native UI adapter for Settings and palette updates. The owner chooses
/// commands, journals creation and reports terminal outcomes.
@MainActor
@Observable
public final class AgentCLIUpdateActions {
    public typealias JSONValue = CmuxNextSettings.JSONValue
    /// One captured machine/session owner; every call rechecks `isCurrent`.
    public struct Route {
        let machine: ResourceID
        let session: ResourceID
        let isCurrent: @MainActor () -> Bool
        let inventory: @MainActor () async throws -> AcpmuxHarnessInventory
        let start: @MainActor (AgentCLIFamily, String) async throws -> AgentCLIJobReceipt
        let observe: @MainActor (AgentCLIJobReceipt) async throws -> AgentCLIJobStatus
        var resolve: (@MainActor (AgentCLIFamily, String) async throws -> AgentCLIJobResolution)?
        var changes: (@MainActor () -> AsyncStream<Void>)?

        public init(machine: ResourceID, session: ResourceID, isCurrent: @escaping @MainActor () -> Bool,
                    inventory: @escaping @MainActor () async throws -> AcpmuxHarnessInventory,
                    start: @escaping @MainActor (AgentCLIFamily, String) async throws -> AgentCLIJobReceipt,
                    observe: @escaping @MainActor (AgentCLIJobReceipt) async throws -> AgentCLIJobStatus,
                    resolve: (@MainActor (AgentCLIFamily, String) async throws -> AgentCLIJobResolution)? = nil,
                    changes: (@MainActor () -> AsyncStream<Void>)? = nil) {
            self.machine = machine
            self.session = session
            self.isCurrent = isCurrent
            self.inventory = inventory
            self.start = start
            self.observe = observe
            self.resolve = resolve
            self.changes = changes
        }
    }

    struct Persistence {
        let record: @MainActor ([AgentCLIUpdateIntent]) async throws -> Void
        let list: @MainActor () async throws -> [AgentCLIStoredIntent]
        let attach: @MainActor (AgentCLIUpdateIntent, AgentCLIJobReceipt) async throws -> Void
        /// Deletes settled rows so they no longer block, resume or fill the ledger.
        let settle: @MainActor ([String]) async throws -> Void
    }

    let capture: @MainActor (ActionInvocation) throws -> Route
    let persistence: Persistence?
    let captureRecovered: @MainActor (ResourceID, ResourceID) throws -> Route
    /// The app's localized refusal; the module holds no app string table.
    let unsupported: @MainActor () -> String
    /// The app's refusal when no listed CLI is one the owner can update.
    let nothingToUpdate: @MainActor () -> String
    /// The app's refusal while an earlier update of the same CLI has not ended.
    let stillUpdating: @MainActor (String) -> String
    /// The target Settings updates name (the app's local machine id).
    let localMachine: String
    var intents: [String: Intent] = [:]
    var retained: [AgentCLIStoredIntent] = []
    /// Keys with a terminal outcome. Their ledger rows are deleted, retried on the next recovery.
    var settled: Set<String> = []
    /// When recovery first saw each key still pending; a long-pending creation may be dismissed.
    var pendingSince: [String: Date] = [:]
    var now: @MainActor () -> Date = { Date() }
    /// How long a creation may stay pending across recoveries before a person may dismiss it.
    static var pendingDismissAfter: TimeInterval { 10 * 60 }

    @Observable final class Intent {
        /// The captured owner; a reconnect to the same machine and session replaces it.
        @ObservationIgnored var route: Route
        let invocation: ActionInvocation
        @ObservationIgnored var work: Task<JSONValue, any Error>?
        @ObservationIgnored var following: Task<Void, Never>?
        var jobs: [JSONValue] = []
        var receipts: [AgentCLIJobReceipt] = []
        var outcomeRevisions: [ResourceID: UInt64] = [:]
        var inputs: [AgentCLIUpdateIntent] = []
        var busy = false
        var restored = false
        /// Child keys of starts whose reply was lost, by family; refresh replays them.
        @ObservationIgnored var unsent: [String: String] = [:]

        var profile: String? { invocation["id"]?.stringValue }

        init(route: Route, invocation: ActionInvocation) {
            self.route = route
            self.invocation = invocation
        }

        nonisolated deinit { following?.cancel() }
    }

    init(capture: @escaping @MainActor (ActionInvocation) throws -> Route, persistence: Persistence? = nil,
         captureRecovered: @escaping @MainActor (ResourceID, ResourceID) throws -> Route = { _, _ in throw DaemonError.notConnected },
         unsupported: (@MainActor () -> String)? = nil,
         nothingToUpdate: (@MainActor () -> String)? = nil,
         stillUpdating: (@MainActor (String) -> String)? = nil,
         localMachine: String = "local") {
        self.capture = capture
        self.persistence = persistence
        self.captureRecovered = captureRecovered
        let unsupported = unsupported ?? { RefusalStrings.needsAppCapability("agent-cli-update") }
        self.unsupported = unsupported
        self.nothingToUpdate = nothingToUpdate ?? unsupported
        self.stillUpdating = stillUpdating ?? { "\($0): \(unsupported())" }
        self.localMachine = localMachine
    }

    public func bind(into registry: ActionRegistry) {
        let run: @MainActor (ActionInvocation) throws -> Void = { [self, weak registry] invocation in
            guard invocation.origin == .user, invocation.callerApp == nil,
                  ActionRunScope.current?.origin == .user else {
                throw ActionFailure(message: RefusalStrings.personOnlyFromPage)
            }
            if let original = invocation["intent"]?.stringValue {
                registry?.track(Task {
                    do { _ = try await self.resume(original); return nil }
                    catch { return ActionWorkFailure(Self.text(error), mayHaveApplied: true, terminalMayAppear: true) }
                })
                return
            }
            let key = DaemonCommandScope.current?.idempotencyKey ?? UUID().uuidString.lowercased()
            let intent: Intent
            if let existing = intents[key] {
                guard !existing.restored else { throw ActionFailure(message: unsupported()) }
                guard existing.profile == invocation["id"]?.stringValue, existing.invocation.target == invocation.target else {
                    throw ActionFailure(message: unsupported())
                }
                intent = existing
            } else {
                intent = Intent(route: try capture(invocation), invocation: invocation)
                intents[key] = intent
            }
            if intent.work == nil {
                // task-owner: one explicit UI intent, retained for same-key replies;
                // observation and page cancellation never cancel the owner's process.
                intent.work = Task { try await self.start(intent, key: key) }
            }
            guard let work = intent.work, let registry else { return }
            guard registry.isCapturingWork else {
                // task-owner: a run no caller waits for (the palette) shows its failure
                // once the owner answers; it never cancels the update itself.
                Task { [weak registry] in
                    do { _ = try await work.value } catch { registry?.refuse(Self.text(error)) }
                }
                return
            }
            registry.track(Task {
                do { _ = try await work.value; return nil }
                catch { return ActionWorkFailure(Self.text(error), mayHaveApplied: !intent.jobs.isEmpty,
                                                terminalMayAppear: !intent.jobs.isEmpty) }
            })
        }
        registry.bind("agent.harness.updateAll", invoke: { [weak registry] invocation in
            do { try run(invocation) } catch { registry?.refuse(RefusalStrings.describe(error)) }
        })
    }

    /// Settings' Update (`id`), Update All, Resume and Dismiss gestures (`cmux.settings.harnesses.run`).
    /// Resume and Dismiss name a retained intent key, never a new operation id.
    public func runPage(_ params: JSONValue, context: PageCallContext, registry: ActionRegistry) async throws -> JSONValue {
        let action = params["action"]?.stringValue
        guard action == "resumeUpdate" || action == "dismissUpdate" else {
            return try await runSettings(id: action == "update" ? params["id"]?.stringValue : nil, context: context, registry: registry)
        }
        guard let key = params["intent"]?.stringValue, !key.isEmpty else {
            throw PageError.invalidParams("\(action ?? "") needs the retained intent key")
        }
        if action == "resumeUpdate" { return try await resumeRetained(key: key, context: context, registry: registry) }
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        try await dismiss(key)
        return state
    }

    /// Settings uses the same registry handler, with the host's context and
    /// operation id kept outside page-controlled arguments.
    func runSettings(id: String?, context: PageCallContext, registry: ActionRegistry) async throws -> JSONValue {
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        let key = context.opid ?? UUID().uuidString.lowercased()
        let scope = DaemonCommandScope(idempotencyKey: key)
        let invocation = ActionInvocation(target: .init(kind: .machine, id: localMachine),
            arguments: id.map { ["id": .string($0)] } ?? [:], origin: .user)
        return try await runRegistry(invocation, scope: scope, registry: registry)
    }

    /// A new gesture authorizes the retained intent, never a replacement key.
    func resumeRetained(key: String, context: PageCallContext, registry: ActionRegistry) async throws -> JSONValue {
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        return try await runRegistry(ActionInvocation(arguments: ["intent": .string(key)], origin: .user),
            scope: DaemonCommandScope(idempotencyKey: key), registry: registry)
    }

    private func runRegistry(_ invocation: ActionInvocation, scope: DaemonCommandScope, registry: ActionRegistry) async throws -> JSONValue {
        let work = DaemonCommandScope.$current.withValueInTask(scope) {
            registry.capturingWork { registry.perform("agent.harness.updateAll", invocation: invocation) }
        }
        guard !work.isEmpty else { throw PageError.unavailable(unsupported()) }
        for task in work {
            if let failure = await task.value { throw PageError.unavailable(failure.message) }
        }
        return state
    }

    /// Explicit refresh observes retained terminals, never starts a new update.
    public func refresh() async {
        do { try await recover() } catch { return }
        await replayUnsent()
        await observeRetained()
    }

    private func observeRetained() async {
        for intent in intents.values where !intent.busy {
            guard let route = owner(of: intent) else { continue }
            await observe(intent, route: route)
        }
    }

    /// The jobs whose owner the app still routes to, then every retained row none of them shows:
    /// what blocks a CLI in `start` is always shown.
    public var state: JSONValue {
        let reachable = intents.keys.sorted().flatMap { key -> [JSONValue] in
            guard let intent = intents[key], owner(of: intent) != nil else { return [] }
            return intent.jobs
        }
        return .array(reachable + unreachableRows().map(Self.unreachableJob))
    }

    /// The intent's owner while the app still routes to it: the captured route, or after a
    /// reconnect to the same machine and session a fresh capture, so its receipts stay
    /// observable. Nil once that owner is gone; its in-memory jobs then neither show nor block
    /// (its ledger row still blocks, see `start`).
    /// Showing, refreshing and blocking all use this one rule. A recovered intent has no
    /// invocation of its own, so recovery's exact machine/session capture is tried too.
    func owner(of intent: Intent) -> Route? {
        if intent.route.isCurrent() { return intent.route }
        let machine = intent.route.machine, session = intent.route.session
        let recaptures: [@MainActor () throws -> Route] = [{ try self.capture(intent.invocation) },
                                                           { try self.captureRecovered(machine, session) }]
        for recapture in recaptures {
            guard let route = try? recapture(), route.isCurrent(), route.machine == machine, route.session == session else { continue }
            // Observation follows the replacement owner; cancelling it never ends the owner's job.
            intent.following?.cancel(); intent.following = nil
            intent.route = route
            follow(intent)
            return route
        }
        return nil
    }

    private func start(_ intent: Intent, key: String) async throws -> JSONValue {
        guard let persistence else { throw DaemonError.notConnected }
        intent.busy = true
        defer { intent.busy = false }
        try await recover()
        await observeRetained()
        // The owner this intent captured. Showing or refreshing may swap `intent.route` for a
        // re-capture after a reconnect, but a start never continues on another connection.
        let route = intent.route
        guard route.isCurrent() else { throw DaemonError.notConnected }
        let inventory = try await route.inventory()
        guard route.isCurrent() else { throw DaemonError.notConnected }
        let rows = inventory.harnesses.filter { intent.profile == nil ? $0.outdated : $0.id == intent.profile }
        let families = Set(rows.compactMap { row -> String? in
            guard let family = row.family, family != .unknown,
                  Self.ownerCanRun(family, in: inventory.harnesses) else { return nil }
            return family.rawValue
        }).sorted()
        guard !families.isEmpty, intent.profile == nil || families.count == 1 else {
            throw ActionFailure(message: families.isEmpty ? nothingToUpdate() : unsupported())
        }
        // One family's refusal never stops the others; the batch reports every failure.
        var failures: [String] = []
        var inputs: [AgentCLIUpdateIntent] = []
        for family in families {
            guard route.isCurrent(), let cli = AgentCLIFamily(rawValue: family) else { throw DaemonError.notConnected }
            // Any session's row blocks: an unreachable session may still be a live server on this
            // machine running the updater. The ledger's seven-day read bound retires true orphans.
            guard !retained.contains(where: { row in
                row.intent.machine == route.machine && row.intent.cli == family && !settled.contains(row.intent.key)
            }), !intents.values.contains(where: { other in
                other !== intent && other.jobs.contains { job in
                    job["machine"]?.stringValue == route.machine.rawValue && job["cli"]?.stringValue == family
                        && ["unknown", "created", "pending"].contains(job["state"]?.stringValue ?? "")
                } && owner(of: other) != nil
            }) else {
                failures.append(stillUpdating(family))
                continue
            }
            // Batch children derive from the original intent and family, not row order.
            let childKey = intent.profile != nil ? key
                : SHA256.hash(data: Data("cmux/agent-update/\(family)/\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
            inputs.append(try AgentCLIUpdateIntent(key: childKey, rootKey: key, machine: route.machine,
                session: route.session, cli: cli, profiles: rows.filter { $0.family?.rawValue == family }.map(\.id)))
        }
        intent.inputs = inputs
        intent.jobs = inputs.map(Self.job)
        // Commit the entire batch before the first request can start an updater.
        if !inputs.isEmpty {
            do { try await persistence.record(inputs) } catch {
                // Nothing started; no unrecorded job may block a later update.
                intent.inputs = []; intent.jobs = []
                throw error
            }
        }
        // A batch that stops early (the route went away, or a receipt for another owner) never
        // sent its remaining families: they settle, so no unsent row blocks a later update, and
        // the failure names each of them.
        for (sent, input) in inputs.enumerated() {
            guard route.isCurrent() else {
                throw await stopEarly(intent, dropping: inputs[sent...], failures: failures, cause: DaemonError.notConnected)
            }
            let listed = failures.count
            do {
                try await send(input, intent: intent, route: route, failures: &failures)
            } catch {
                if failures.count == listed { failures.append("\(input.cli): \(Self.text(error))") }
                throw await stopEarly(intent, dropping: inputs[(sent + 1)...], failures: failures, cause: error)
            }
        }
        guard failures.isEmpty else { throw ActionFailure(message: failures.joined(separator: "\n")) }
        return .array(intent.jobs)
    }

    /// Settles the families a stopped batch never sent and names them with the failures so far.
    private func stopEarly(_ intent: Intent, dropping left: ArraySlice<AgentCLIUpdateIntent>,
                           failures: [String], cause: any Error) async -> ActionFailure {
        for input in left { await settle(input.key, in: intent) }
        return ActionFailure(message: (failures + left.map { "\($0.cli): \(Self.text(cause))" }).joined(separator: "\n"))
    }

    /// The rows of a `_acpmux/harness/health` answer by harness id; nil when it is not one.
    public nonisolated static func healthRows(_ data: Data) -> [String: JSONValue]? {
        guard let rows = (try? JSONValue.parse(data))?["harnesses"]?.arrayValue else { return nil }
        return Dictionary(rows.compactMap { row in row["id"]?.stringValue.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
    }

    static func text(_ error: any Error) -> String {
        (error as? ActionFailure)?.message ?? (error as? DaemonError)?.description ?? error.localizedDescription
    }

    /// The owner prepares only npm, Bun and native installations (acpmux `fixed_argv`),
    /// and refuses a family when any of its rows is another channel or current.
    static func ownerCanRun(_ family: AgentCLIFamily, in rows: [AcpmuxHarnessInventory.Harness]) -> Bool {
        let members = rows.filter { $0.family == family }
        return !members.isEmpty && members.allSatisfy { $0.outdated && [.npm, .bun, .native].contains($0.channel) }
    }

    /// The owner answers `agent_cli_job.*` before it journals a creation, so no
    /// terminal exists for the key. Any other failure may follow a creation.
    static func refusedBeforeCreation(_ error: any Error) -> Bool {
        guard case DaemonError.command(_, _, let code?, _, _) = error else { return false }
        // Busy is not a refusal on a replay or resume: the owner may be running this very key.
        // A first start's fresh key cannot be running, so `send` settles busy too.
        return code.hasPrefix("agent_cli_job.") && !busy(error)
    }

    /// The owner's execution lock or inventory reservation is held.
    static func busy(_ error: any Error) -> Bool {
        guard case DaemonError.command(_, _, let code?, _, _) = error else { return false }
        return code == "agent_cli_job.busy"
    }

    /// `terminal.wait_exit` on a closed terminal: `terminal.closed`, or `selector.not_found`
    /// for the terminal once tombstoned. A missing session or connection is not this.
    static func terminalGone(_ error: any Error) -> Bool {
        guard case DaemonError.command(_, _, let code?, let details, _) = error else { return false }
        return code == "terminal.closed" || (code == "selector.not_found" && details?["scope"]?.stringValue == "terminal")
    }
}
