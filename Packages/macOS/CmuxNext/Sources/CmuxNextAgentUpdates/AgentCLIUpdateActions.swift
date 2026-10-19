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
    /// The target Settings updates name (the app's local machine id).
    let localMachine: String
    private var intents: [String: Intent] = [:]

    @Observable final class Intent {
        let route: Route
        let profile: String?
        let target: ActionTargetRef?
        @ObservationIgnored var work: Task<JSONValue, any Error>?
        var jobs: [JSONValue] = []
        var receipts: [AgentCLIJobReceipt] = []

        init(route: Route, profile: String?, target: ActionTargetRef?) {
            self.route = route
            self.profile = profile
            self.target = target
        }
    }

    public init(capture: @escaping @MainActor (ActionInvocation) throws -> Route,
                unsupported: (@MainActor () -> String)? = nil,
                localMachine: String = "local") {
        self.capture = capture
        self.unsupported = unsupported ?? { RefusalStrings.needsAppCapability("agent-cli-update") }
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
                guard existing.profile == invocation["id"]?.stringValue, existing.target == invocation.target else {
                    throw ActionFailure(message: unsupported())
                }
                intent = existing
            } else {
                intent = Intent(route: try capture(invocation), profile: invocation["id"]?.stringValue, target: invocation.target)
                intents[key] = intent
            }
            if intent.work == nil {
                // task-owner: one explicit UI intent, retained for same-key replies;
                // observation and page cancellation never cancel the owner's process.
                intent.work = Task { try await self.start(intent, key: key) }
            }
            guard let work = intent.work else { return }
            registry?.track(Task {
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
        let work = DaemonCommandScope.$current.withValue(scope) {
            registry.capturingWork { registry.perform("agent.harness.updateAll", invocation: invocation) }
        }
        guard !work.isEmpty else { throw PageError.unavailable(unsupported()) }
        for task in work {
            if let failure = await task.value { throw PageError.unavailable(failure.message) }
        }
        return .array(intents[key]?.jobs ?? [])
    }

    /// Explicit refresh observes retained terminals, never starts a new update.
    public func refresh() async {
        for intent in intents.values where intent.route.isCurrent() {
            for receipt in intent.receipts {
                guard intent.route.isCurrent() else { break }
                do {
                    let status = try await intent.route.observe(receipt)
                    guard intent.route.isCurrent(), status.terminalID == receipt.path.terminalID,
                          let index = intent.jobs.firstIndex(where: { $0["terminal"]?.stringValue == status.terminalID.rawValue }),
                          var job = intent.jobs[index].objectValue else { continue }
                    job["state"] = .string(status.state.rawValue)
                    if case .exit(let code) = status.outcome { job["exit_code"] = .number(Double(code)) }
                    if case .signal(let number) = status.outcome { job["signal"] = .number(Double(number)) }
                    if case .unknown = status.outcome { job["state"] = "unknown" }
                    intent.jobs[index] = .object(job)
                } catch {
                    // Keep the receipt and original route; a failed observation is no completion.
                }
            }
        }
    }

    public var state: JSONValue {
        .array(intents.keys.sorted().flatMap { key in
            guard let intent = intents[key], intent.route.isCurrent() else { return [JSONValue]() }
            return intent.jobs
        })
    }

    private func start(_ intent: Intent, key: String) async throws -> JSONValue {
        guard intent.route.isCurrent() else { throw DaemonError.notConnected }
        let inventory = try await intent.route.inventory()
        guard intent.route.isCurrent() else { throw DaemonError.notConnected }
        let rows = inventory.harnesses.filter { intent.profile == nil ? $0.outdated : $0.id == intent.profile }
        let families = Set(rows.compactMap { row -> String? in
            guard let family = row.family, family != .unknown,
                  Self.ownerCanRun(family, in: inventory.harnesses) else { return nil }
            return family.rawValue
        }).sorted()
        guard !families.isEmpty, intent.profile == nil || families.count == 1 else {
            throw ActionFailure(message: unsupported())
        }
        // One family's refusal never stops the others; the batch reports every failure.
        var failures: [String] = []
        for family in families {
            guard intent.route.isCurrent(), let cli = AgentCLIFamily(rawValue: family) else { throw DaemonError.notConnected }
            guard !intents.values.contains(where: { other in
                other !== intent && other.jobs.contains { job in
                    job["machine"]?.stringValue == intent.route.machine.rawValue && job["cli"]?.stringValue == family
                        && ["unknown", "created", "pending"].contains(job["state"]?.stringValue ?? "")
                }
            }) else {
                failures.append("\(family): \(unsupported())")
                continue
            }
            // Batch children derive from the original intent and family, not row order.
            let childKey = intent.profile != nil ? key
                : SHA256.hash(data: Data("cmux/agent-update/\(family)/\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
            var job: [String: JSONValue] = ["machine": .string(intent.route.machine.rawValue),
                "session": .string(intent.route.session.rawValue), "cli": .string(family), "state": "unknown",
                "profiles": .array(rows.filter { $0.family?.rawValue == family }.map { .string($0.id) })]
            intent.jobs.append(.object(job))
            let index = intent.jobs.count - 1
            let receipt: AgentCLIJobReceipt
            do {
                receipt = try await intent.route.start(cli, childKey)
            } catch {
                // A refusal created nothing, so it leaves no job to block this CLI.
                // A lost reply may have created the terminal and stays unknown.
                if Self.refusedBeforeCreation(error) { intent.jobs.remove(at: index) }
                failures.append("\(family): \(Self.text(error))")
                guard intent.route.isCurrent() else { throw error }
                continue
            }
            guard receipt.machine == intent.route.machine, receipt.session == intent.route.session, receipt.cli == cli else {
                throw DaemonError.malformedResponse("Agent update receipt owner mismatch")
            }
            intent.receipts.append(receipt)
            job["terminal"] = .string(receipt.path.terminalID.rawValue)
            job["state"] = "created"
            intent.jobs[index] = .object(job)
            guard intent.route.isCurrent() else { throw DaemonError.notConnected }
        }
        guard failures.isEmpty else { throw ActionFailure(message: failures.joined(separator: "\n")) }
        return .array(intent.jobs)
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
