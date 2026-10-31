import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextAgentUpdates
import CmuxNextSettings
import Foundation
import Observation

/// The app's one path to the acpmux harness operations (BRING-YOUR-OWN-HARNESS H1, H2): the
/// `agent.harness.*` actions (palette, CLI, MCP) and Settings > Agents call these methods, so
/// each gesture runs the same daemon request with the same refusals. The daemon owns the profile
/// files; this type keeps only what Settings draws (the list, the last registry answer, doctor
/// results and the last removal for Undo), refreshed after each change and on the daemon's
/// `_acpmux/harnesses_changed` while Settings watches. No polling.
@MainActor
@Observable
final class AgentHarnessCenter {
    private(set) var updates: AgentCLIUpdateActions?
    /// What Settings draws (`cmux.settings.agents.state`).
    private(set) var pageState: JSONValue = ["status": "loading", "harnesses": .array([])]

    @ObservationIgnored private let environment: @MainActor () -> AcpmuxEnvironment?
    @ObservationIgnored private var list: JSONValue?
    @ObservationIgnored private var status = "loading"
    @ObservationIgnored private var message: String?
    /// False once the daemon answered "no such method" to a manage request (an older acpmux):
    /// Settings then shows the CLI commands instead of the buttons.
    @ObservationIgnored private var manages = true
    @ObservationIgnored private var registry: JSONValue?
    @ObservationIgnored private var doctors: [String: JSONValue] = [:]
    @ObservationIgnored private var removed: JSONValue?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// SF Symbol images for Settings' harness icons (`agents.run {action: "symbol"}`).
    @ObservationIgnored let symbols = HarnessSymbolImages()

    init(environment: @escaping @MainActor () -> AcpmuxEnvironment?) {
        self.environment = environment
    }

    convenience init(services: AppServices) {
        self.init(environment: { [weak services] in services.flatMap(QuitAgents.environment) })
        updates = AgentCLIUpdateActions(services: services)
    }

    /// The backup of the last removal this app made, for Undo and `agent.harness.restore`.
    var lastRemovedBackup: String? { removed?["backup"]?.stringValue }

    // MARK: Operations

    /// The harness list again (`_acpmux/harnesses`).
    func refresh() async {
        do {
            list = try await call(.list)
            status = "ready"
            message = nil
        } catch {
            status = "unreachable"
            message = Self.text(error)
        }
        publish()
    }

    /// The ACP Registry's agents (`_acpmux/registry`); `refresh` fetches it now.
    @discardableResult
    func loadRegistry(refresh: Bool = false) async throws -> JSONValue {
        let answer = try await manage(.registry, refresh ? ["refresh": true] : [:])
        registry = answer
        publish()
        return answer
    }

    /// Writes a profile (`_acpmux/harness/add`); the list follows.
    @discardableResult
    func add(_ request: AgentHarnessAddRequest) async throws -> JSONValue {
        let answer = try await manage(.add, request.params)
        removed = nil
        await refresh()
        return answer
    }

    /// Moves a user profile aside (`_acpmux/harness/remove`); the answer's `backup` restores it.
    @discardableResult
    func remove(id: String) async throws -> JSONValue {
        let answer = try await manage(.remove, ["id": id])
        removed = ["id": .string(id), "backup": answer["backup"] ?? .null]
        doctors[id] = nil
        await refresh()
        return answer
    }

    /// Puts a removed profile back (`_acpmux/harness/restore`).
    @discardableResult
    func restore(backup: String) async throws -> JSONValue {
        let answer = try await manage(.restore, ["backup": backup])
        if removed?["backup"]?.stringValue == backup { removed = nil }
        await refresh()
        return answer
    }

    /// Sets a user profile's icon (`_acpmux/harness/icon`); the list, with each harness's new
    /// `iconSpec`, follows. A nil change is a request Settings made without a value.
    @discardableResult
    func setIcon(id: String, change: AgentHarnessIconChange?) async throws -> JSONValue {
        guard let change else { throw PageError.invalidParams("give icon, data or clear") }
        let answer = try await manage(.icon, change.params(id: id))
        await refresh()
        return answer
    }

    /// Starts the harness and runs the ACP handshake (`_acpmux/harness/doctor`); Settings shows
    /// the steps. `noPrompt` stops after session/new (no model call); otherwise the check sends one
    /// real hello turn (`prompt: true`), what the Chief editor needs before it saves a backend.
    @discardableResult
    func doctor(id: String, noPrompt: Bool = false) async throws -> JSONValue {
        doctors[id] = ["running": true]
        publish()
        do {
            let answer = try await manage(.doctor, noPrompt ? ["id": id, "noPrompt": true] : ["id": id, "prompt": true])
            doctors[id] = answer
            publish()
            return answer
        } catch {
            doctors[id] = ["ok": false, "steps": .array([["name": "doctor", "ok": false, "detail": .string(Self.text(error))]])]
            publish()
            throw error
        }
    }

    /// Stores `value` in the Keychain for harness `id` under `key` (`_acpmux/harness/secret/set`)
    /// and answers the item name the profile reads (`keychain:NAME`). The value goes only into
    /// this one request: never a log, a state Settings draws, or a profile.
    func setSecret(id: String, key: String, value: String) async throws -> String {
        let answer: JSONValue
        do {
            answer = try await call(.secretSet, ["id": id, "key": key, "value": value])
        } catch let error as AcpmuxRPCError where error.isMethodMissing {
            // An acpmux without the Keychain write: the endpoint cannot be added from the app. The
            // other harness buttons in Settings still work, so this does not switch them off.
            throw AgentHarnessFailure.unsupported
        }
        return answer["item"]?.stringValue ?? "cmux-harness/\(id)/\(key)"
    }

    /// `_acpmux/models`: every harness's probed models, with their efforts.
    func models() async throws -> JSONValue {
        try await call(.models)
    }

    /// `_acpmux/harnesses` as the daemon answers it (the Chief editor's backend list).
    func harnessList() async throws -> JSONValue {
        try await call(.list)
    }

    // MARK: Watching

    /// Settings shows the list: follow `_acpmux/harnesses_changed` until the last watcher leaves.
    func beginWatching() {
        watchers += 1
        guard watchers == 1, let environment = environment() else { return }
        watch = environment.watchHarnesses { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        watch?.cancel()
        watch = nil
    }

    // MARK: Plumbing

    private func manage(_ method: AcpmuxHarnessMethod, _ params: [String: any Sendable]) async throws -> JSONValue {
        do {
            return try await call(method, params)
        } catch let error as AcpmuxRPCError where error.isMethodMissing {
            manages = false
            publish()
            throw AgentHarnessFailure.unsupported
        }
    }

    /// The ids of the daemon's harnesses (`_acpmux/harnesses`), as Settings > Agents lists them.
    func listed() async throws -> [String] {
        try await call(.list)["harnesses"]?.objectValue.map { Array($0.keys) } ?? []
    }

    /// `_acpmux/harness/health` (cx-ny85): the daemon's last check of every harness.
    func health() async throws -> [JSONValue] {
        try await call(.health)["harnesses"]?.arrayValue ?? []
    }

    private func call(_ method: AcpmuxHarnessMethod, _ params: [String: any Sendable] = [:]) async throws -> JSONValue {
        guard let environment = environment() else { throw AgentHarnessFailure.noDaemon }
        do {
            return try JSONValue.parse(try await environment.harness(method, params: params))
        } catch let error as AcpmuxRPCError where error.isUnreachable {
            throw AgentHarnessFailure.noDaemon
        }
    }

    private func publish() {
        var state: [String: JSONValue] = [
            "status": .string(status),
            "manages": .bool(manages),
            "harnesses": .array(AgentHarnessRows.rows(list)),
            "doctor": .object(doctors),
        ]
        if let message { state["message"] = .string(message) }
        if let registry { state["registry"] = registry }
        if let removed { state["removed"] = removed }
        pageState = .object(state)
    }

    static func text(_ error: any Error) -> String {
        (error as? AgentHarnessFailure)?.message ?? (error as? AcpmuxRPCError)?.message
            ?? (error as? ActionFailure)?.message ?? error.localizedDescription
    }
}
