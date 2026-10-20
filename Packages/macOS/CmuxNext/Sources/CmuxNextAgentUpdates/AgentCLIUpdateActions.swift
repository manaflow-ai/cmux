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

        public init(machine: ResourceID, session: ResourceID, isCurrent: @escaping @MainActor () -> Bool,
                    inventory: @escaping @MainActor () async throws -> AcpmuxHarnessInventory,
                    start: @escaping @MainActor (AgentCLIFamily, String) async throws -> AgentCLIJobReceipt,
                    observe: @escaping @MainActor (AgentCLIJobReceipt) async throws -> AgentCLIJobStatus) {
            self.machine = machine
            self.session = session
            self.isCurrent = isCurrent
            self.inventory = inventory
            self.start = start
            self.observe = observe
        }
    }

    private let capture: @MainActor (ActionInvocation) throws -> Route
    /// The app's localized refusal; the module holds no app string table.
    let unsupported: @MainActor () -> String
    /// The app's refusal when no listed CLI is one the owner can update.
    let nothingToUpdate: @MainActor () -> String
    /// The app's refusal while an earlier update of the same CLI has not ended.
    let stillUpdating: @MainActor (String) -> String
    /// The target Settings updates name (the app's local machine id).
    let localMachine: String
    private var intents: [String: Intent] = [:]

    @Observable final class Intent {
        /// The captured owner; a reconnect to the same machine and session replaces it.
        @ObservationIgnored var route: Route
        let invocation: ActionInvocation
        @ObservationIgnored var work: Task<JSONValue, any Error>?
        var jobs: [JSONValue] = []
        var receipts: [AgentCLIJobReceipt] = []
        /// Child keys of starts whose reply was lost, by family; refresh replays them.
        @ObservationIgnored var unsent: [String: String] = [:]

        var profile: String? { invocation["id"]?.stringValue }

        init(route: Route, invocation: ActionInvocation) {
            self.route = route
            self.invocation = invocation
        }
    }

    public init(capture: @escaping @MainActor (ActionInvocation) throws -> Route,
                unsupported: (@MainActor () -> String)? = nil,
                nothingToUpdate: (@MainActor () -> String)? = nil,
                stillUpdating: (@MainActor (String) -> String)? = nil,
                localMachine: String = "local") {
        self.capture = capture
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
            let key = DaemonCommandScope.current?.idempotencyKey ?? UUID().uuidString.lowercased()
            let intent: Intent
            if let existing = intents[key] {
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

    /// Settings' Update (`id`) and Update All gestures (`cmux.settings.harnesses.run`).
    public func runPage(_ params: JSONValue, context: PageCallContext, registry: ActionRegistry) async throws -> JSONValue {
        try await runSettings(id: params["action"]?.stringValue == "update" ? params["id"]?.stringValue : nil,
                              context: context, registry: registry)
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
        let work = DaemonCommandScope.$current.withValueInTask(scope) {
            registry.capturingWork { registry.perform("agent.harness.updateAll", invocation: invocation) }
        }
        guard !work.isEmpty else { throw PageError.unavailable(unsupported()) }
        for task in work {
            if let failure = await task.value { throw PageError.unavailable(failure.message) }
        }
        return .array(intents[key]?.jobs ?? [])
    }

    /// Explicit refresh observes retained terminals, never starts a new update. A start
    /// whose reply was lost is sent again with its key; the owner replays it by that key.
    public func refresh() async {
        for intent in intents.values {
            for (family, childKey) in intent.unsent.sorted(by: { $0.key < $1.key }) {
                guard let route = owner(of: intent), let cli = AgentCLIFamily(rawValue: family) else { break }
                let result: Result<AgentCLIJobReceipt, any Error>
                do { result = .success(try await route.start(cli, childKey)) } catch { result = .failure(error) }
                guard intent.unsent[family] == childKey, let index = Self.job(of: family, in: intent) else { continue }
                switch result {
                case .success(let receipt):
                    guard route.isCurrent() else { continue }
                    intent.unsent[family] = nil
                    guard receipt.machine == route.machine, receipt.session == route.session, receipt.cli == cli else {
                        intent.jobs.remove(at: index)
                        continue
                    }
                    intent.receipts.append(receipt)
                    if var job = intent.jobs[index].objectValue {
                        job["terminal"] = .string(receipt.path.terminalID.rawValue)
                        job["state"] = "created"
                        intent.jobs[index] = .object(job)
                    }
                case .failure(let error):
                    // The owner's refusal says the key created nothing; anything else may follow a creation.
                    guard Self.refusedBeforeCreation(error) else { continue }
                    intent.unsent[family] = nil
                    intent.jobs.remove(at: index)
                }
            }
            for receipt in intent.receipts {
                guard let route = owner(of: intent) else { break }
                do {
                    let status = try await route.observe(receipt)
                    guard route.isCurrent(), status.terminalID == receipt.path.terminalID,
                          let index = intent.jobs.firstIndex(where: { $0["terminal"]?.stringValue == status.terminalID.rawValue }),
                          var job = intent.jobs[index].objectValue else { continue }
                    // An end observation settles the job even when it has no process result.
                    job["state"] = .string(status.state.rawValue)
                    switch status.outcome {
                    case .exit(let code): job["exit_code"] = .number(Double(code))
                    case .signal(let number): job["signal"] = .number(Double(number))
                    case .unknown: job["outcome"] = "unknown"
                    case nil: break
                    }
                    intent.jobs[index] = .object(job)
                } catch {
                    // Keep the receipt; a failed observation is no completion.
                }
            }
        }
    }

    public var state: JSONValue {
        .array(intents.keys.sorted().flatMap { key in
            guard let intent = intents[key], owner(of: intent) != nil else { return [JSONValue]() }
            return intent.jobs
        })
    }

    /// The intent's owner while the app still routes to it: the captured route, or after a
    /// reconnect to the same machine and session a fresh capture, so its receipts stay
    /// observable. Nil once that owner is gone; its jobs then neither show nor block.
    /// Showing, refreshing and blocking all use this one rule.
    private func owner(of intent: Intent) -> Route? {
        if intent.route.isCurrent() { return intent.route }
        guard let route = try? capture(intent.invocation), route.isCurrent(),
              route.machine == intent.route.machine, route.session == intent.route.session else { return nil }
        intent.route = route
        return route
    }

    private func start(_ intent: Intent, key: String) async throws -> JSONValue {
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
        for family in families {
            guard route.isCurrent(), let cli = AgentCLIFamily(rawValue: family) else { throw DaemonError.notConnected }
            guard !intents.values.contains(where: { other in
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
            var job: [String: JSONValue] = ["machine": .string(route.machine.rawValue),
                "session": .string(route.session.rawValue), "cli": .string(family), "state": "unknown",
                "profiles": .array(rows.filter { $0.family?.rawValue == family }.map { .string($0.id) })]
            intent.jobs.append(.object(job))
            let receipt: AgentCLIJobReceipt
            do {
                receipt = try await route.start(cli, childKey)
            } catch {
                // A refusal created nothing, so it leaves no job to block this CLI.
                // A lost reply may have created the terminal: it stays unknown, and
                // refresh sends the same key again to learn which.
                if Self.refusedBeforeCreation(error) {
                    if let index = Self.job(of: family, in: intent) { intent.jobs.remove(at: index) }
                } else {
                    intent.unsent[family] = childKey
                }
                failures.append("\(family): \(Self.text(error))")
                guard route.isCurrent() else { throw error }
                continue
            }
            guard let index = Self.job(of: family, in: intent) else { throw DaemonError.notConnected }
            guard receipt.machine == route.machine, receipt.session == route.session, receipt.cli == cli else {
                // Another owner's terminal is not this update's, and this route cannot observe it.
                intent.jobs.remove(at: index)
                throw DaemonError.malformedResponse("Agent update receipt owner mismatch")
            }
            intent.receipts.append(receipt)
            job["terminal"] = .string(receipt.path.terminalID.rawValue)
            job["state"] = "created"
            intent.jobs[index] = .object(job)
            guard route.isCurrent() else { throw DaemonError.notConnected }
        }
        guard failures.isEmpty else { throw ActionFailure(message: failures.joined(separator: "\n")) }
        return .array(intent.jobs)
    }

    /// The intent's job for one family that has no terminal yet; an intent runs each family once.
    private static func job(of family: String, in intent: Intent) -> Int? {
        intent.jobs.lastIndex { $0["cli"]?.stringValue == family && $0["terminal"] == nil }
    }

    /// The rows of a `_acpmux/harness/health` answer by harness id; nil when it is not one.
    public nonisolated static func healthRows(_ data: Data) -> [String: JSONValue]? {
        guard let rows = (try? JSONValue.parse(data))?["harnesses"]?.arrayValue else { return nil }
        return Dictionary(rows.compactMap { row in row["id"]?.stringValue.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
    }

    static func text(_ error: any Error) -> String {
        (error as? ActionFailure)?.message ?? (error as? DaemonError)?.description ?? error.localizedDescription
    }

    /// The owner prepares only npm and native installations (acpmux `fixed_argv`),
    /// and refuses a family when any of its rows is another channel or current.
    static func ownerCanRun(_ family: AgentCLIFamily, in rows: [AcpmuxHarnessInventory.Harness]) -> Bool {
        let members = rows.filter { $0.family == family }
        return !members.isEmpty && members.allSatisfy { $0.outdated && ($0.channel == .npm || $0.channel == .native) }
    }

    /// The owner answers `agent_cli_job.*` before it journals a creation, so no
    /// terminal exists for the key. Any other failure may follow a creation.
    static func refusedBeforeCreation(_ error: any Error) -> Bool {
        guard case DaemonError.command(_, _, let code?, _, _) = error else { return false }
        return code.hasPrefix("agent_cli_job.")
    }
}
