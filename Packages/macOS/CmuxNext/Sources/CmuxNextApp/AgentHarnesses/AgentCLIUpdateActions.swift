import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSettings
import CryptoKit
import Foundation
import Observation

/// The native UI adapter for Settings and palette updates. The owner chooses
/// commands, journals creation and reports terminal outcomes.
@MainActor
@Observable
final class AgentCLIUpdateActions {
    typealias JSONValue = CmuxNextSettings.JSONValue
    struct Route {
        let machine: ResourceID
        let session: ResourceID
        let isCurrent: @MainActor () -> Bool
        let inventory: @MainActor () async throws -> AcpmuxHarnessInventory
        let start: @MainActor (AgentCLIFamily, String) async throws -> AgentCLIJobReceipt
        let observe: @MainActor (AgentCLIJobReceipt) async throws -> AgentCLIJobStatus
        var resolve: (@MainActor (AgentCLIFamily, String) async throws -> AgentCLIJobResolution)? = nil
    }

    struct Persistence {
        let record: @MainActor ([AgentCLIUpdateIntent]) async throws -> Void
        let list: @MainActor () async throws -> [AgentCLIStoredIntent]
        let attach: @MainActor (AgentCLIUpdateIntent, AgentCLIJobReceipt) async throws -> Void
    }

    private let capture: @MainActor (ActionInvocation) throws -> Route
    private let persistence: Persistence?
    private let captureRecovered: @MainActor (ResourceID, ResourceID) throws -> Route
    private var intents: [String: Intent] = [:]

    @Observable final class Intent {
        let route: Route
        let profile: String?
        let target: ActionTargetRef?
        @ObservationIgnored var work: Task<JSONValue, Error>?
        var jobs: [JSONValue] = []
        var receipts: [AgentCLIJobReceipt] = []

        init(route: Route, profile: String?, target: ActionTargetRef?) {
            self.route = route
            self.profile = profile
            self.target = target
        }
    }

    init(capture: @escaping @MainActor (ActionInvocation) throws -> Route, persistence: Persistence? = nil,
         captureRecovered: @escaping @MainActor (ResourceID, ResourceID) throws -> Route = { _, _ in throw DaemonError.notConnected }) {
        self.capture = capture
        self.persistence = persistence
        self.captureRecovered = captureRecovered
    }

    /// Restores only the original owner/key and reads its creation receipt.
    func recover() async throws {}

    /// Explicit user consent can resume a previously recorded, unstarted intent.
    func resumeRetained(key: String, context: PageCallContext, registry: ActionRegistry) async throws -> JSONValue {
        throw PageError.unavailable(AgentHarnessStrings.unsupported)
    }

    func bind(into registry: ActionRegistry) {
        registry.bind("agent.harness.updateAll", run: { [self, weak registry] invocation in
            guard invocation.origin == .user, invocation.callerApp == nil,
                  ActionRunScope.current?.origin == .user else {
                throw ActionFailure(message: RefusalStrings.personOnlyFromPage)
            }
            let key = DaemonCommandScope.current?.idempotencyKey ?? UUID().uuidString.lowercased()
            let intent: Intent
            if let existing = intents[key] {
                guard existing.profile == invocation["id"]?.stringValue, existing.target == invocation.target else {
                    throw ActionFailure(message: AgentHarnessStrings.unsupported)
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
                catch { return ActionWorkFailure(AgentHarnessCenter.text(error), mayHaveApplied: !intent.jobs.isEmpty,
                                                terminalMayAppear: !intent.jobs.isEmpty) }
            })
        })
    }

    /// Settings uses the same registry handler, with the host's context and
    /// operation id kept outside page-controlled arguments.
    func runSettings(id: String?, context: PageCallContext, registry: ActionRegistry) async throws -> JSONValue {
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        let key = context.opid ?? UUID().uuidString.lowercased()
        let scope = DaemonCommandScope(idempotencyKey: key)
        let invocation = ActionInvocation(target: .init(kind: .machine, id: MachineRegistry.localID),
            arguments: id.map { ["id": .string($0)] } ?? [:], origin: .user)
        let work = DaemonCommandScope.$current.withValue(scope) {
            registry.capturingWork { registry.perform("agent.harness.updateAll", invocation: invocation) }
        }
        guard !work.isEmpty else { throw PageError.unavailable(AgentHarnessStrings.unsupported) }
        for task in work {
            if let failure = await task.value { throw PageError.unavailable(failure.message) }
        }
        return .array(intents[key]?.jobs ?? [])
    }

    /// Explicit refresh observes retained terminals, never starts a new update.
    func refresh() async {
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

    var state: JSONValue {
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
            guard let family = row.family, family != .unknown, row.channel != .missing, row.channel != .launcher else { return nil }
            return family.rawValue
        }).sorted()
        guard !families.isEmpty, intent.profile == nil || families.count == 1 else {
            throw ActionFailure(message: AgentHarnessStrings.unsupported)
        }
        for family in families {
            guard intent.route.isCurrent(), let cli = AgentCLIFamily(rawValue: family) else { throw DaemonError.notConnected }
            guard !intents.values.contains(where: { other in
                other !== intent && other.jobs.contains { job in
                    job["machine"]?.stringValue == intent.route.machine.rawValue && job["cli"]?.stringValue == family
                        && ["unknown", "created", "pending"].contains(job["state"]?.stringValue ?? "")
                }
            }) else { throw ActionFailure(message: AgentHarnessStrings.unsupported) }
            // Batch children derive from the original intent and family, not row order.
            let childKey = intent.profile != nil ? key
                : SHA256.hash(data: Data("cmux/agent-update/\(family)/\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
            var job: [String: JSONValue] = ["machine": .string(intent.route.machine.rawValue),
                "session": .string(intent.route.session.rawValue), "cli": .string(family), "state": "unknown",
                "profiles": .array(rows.filter { $0.family?.rawValue == family }.map { .string($0.id) })]
            intent.jobs.append(.object(job))
            let receipt = try await intent.route.start(cli, childKey)
            guard receipt.machine == intent.route.machine, receipt.session == intent.route.session, receipt.cli == cli else {
                throw DaemonError.malformedResponse("Agent update receipt owner mismatch")
            }
            intent.receipts.append(receipt)
            job["terminal"] = .string(receipt.path.terminalID.rawValue)
            job["state"] = "created"
            intent.jobs[intent.jobs.count - 1] = .object(job)
            guard intent.route.isCurrent() else { throw DaemonError.notConnected }
        }
        return .array(intent.jobs)
    }
}
