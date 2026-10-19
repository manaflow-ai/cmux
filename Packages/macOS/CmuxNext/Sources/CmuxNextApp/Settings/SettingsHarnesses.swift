import CmuxNextAgentPane
import CmuxNextAgentUpdates
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Observation

/// Settings > Agents > Harnesses (cx-mg91): this app's acpmux harnesses
/// (`_acpmux/harnesses`) for the React Settings page, and its gestures.
/// Sign in, Check and Browse ACP Registry type `acpmux harness login <id>`,
/// `acpmux harness login <id> --status` or `acpmux harness registry` into a
/// new terminal tab of the focused pane, the way Accounts runs a provider's
/// login (`AccountsService.runInTerminal`), so the sign-in runs where the
/// person can see and answer it.
///
/// Health (cx-ny85, `_acpmux/harness/health`) adds each row's installed and newest version, a
/// sign-out the daemon has evidence for, and its update command for display. Update and Update
/// all use the shared owner-bound job action; no health argv is typed into a focused pane.
/// Refresh observes retained job terminals and reads health again.
/// Update Automatically asks acpmux to run a harness's update itself after a check finds it
/// outdated (`_acpmux/harness/health {autoUpdate}`; never one that needs sudo).
@MainActor
@Observable
final class SettingsHarnesses {
    private(set) var rows: [AcpmuxHarnessRow] = []
    /// `_acpmux/harness/health` rows by harness id; empty from a daemon without it.
    private(set) var health: [String: JSONValue] = [:]
    private(set) var loading = false
    /// `unavailable` (no acpmux here) or `unreachable` (the daemon did not answer).
    private(set) var problem: String?
    @ObservationIgnored private let environment: @MainActor () -> AcpmuxEnvironment?
    @ObservationIgnored private let fetch: @Sendable (AcpmuxEnvironment) async throws -> [AcpmuxHarnessRow]
    @ObservationIgnored private let fetchHealth: @Sendable (AcpmuxEnvironment, Bool) async throws -> Data
    @ObservationIgnored private let openTerminal: @MainActor (String) -> Void
    @ObservationIgnored private let runUpdate: (@MainActor (JSONValue, PageCallContext) async throws -> JSONValue)?
    @ObservationIgnored private let updateState: @MainActor () -> JSONValue
    @ObservationIgnored private let refreshUpdates: (@MainActor () async -> Void)?
    @ObservationIgnored private var generation = 0

    init(environment: @escaping @MainActor () -> AcpmuxEnvironment?,
         fetch: @escaping @Sendable (AcpmuxEnvironment) async throws -> [AcpmuxHarnessRow] = { try await $0.harnessRows() },
         fetchHealth: @escaping @Sendable (AcpmuxEnvironment, Bool) async throws -> Data = AcpmuxEnvironment.harnessHealth,
         openTerminal: @escaping @MainActor (String) -> Void,
         runUpdate: (@MainActor (JSONValue, PageCallContext) async throws -> JSONValue)? = nil,
         updateState: @escaping @MainActor () -> JSONValue = { .array([]) },
         refreshUpdates: (@MainActor () async -> Void)? = nil) {
        self.environment = environment
        self.fetch = fetch
        self.fetchHealth = fetchHealth
        self.openTerminal = openTerminal
        self.runUpdate = runUpdate
        self.updateState = updateState
        self.refreshUpdates = refreshUpdates
    }

    /// The page's `cmux.settings.harnesses.state` (webviews/src/pages/settings/ops.ts `HarnessesState`).
    var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "jobs": updateState(),
            "harnesses": .array(rows.map { row -> JSONValue in
                let health = health[row.id]
                let update = health?["update"].flatMap { plan -> JSONValue? in
                    guard let command = plan["command"]?.stringValue else { return nil }
                    return ["command": .string(command), "elevated": .bool(plan["elevated"]?.boolValue ?? true)]
                }
                return [
                    "id": .string(row.id), "name": row.name.map(JSONValue.string) ?? .null, "kind": .string(row.kind),
                    "source": .string(row.source), "problem": row.problem.map(JSONValue.string) ?? .null,
                    "version": health?["version"]?.stringValue.map(JSONValue.string) ?? .null,
                    "latest": health?["latest"]?.stringValue.map(JSONValue.string) ?? .null,
                    "outdated": .bool(health?["outdated"]?.boolValue ?? false),
                    "auth": .string(health?["auth"]?.stringValue ?? "unknown"),
                    "update": update ?? .null,
                    // The update owner runs only npm, Bun and native installations; others show no Update.
                    "ownerUpdate": .bool(["npm", "bun", "native"].contains(health?["channel"]?.stringValue ?? "")),
                    "autoUpdate": .bool(health?["autoUpdate"]?.boolValue ?? false),
                    "lastAutoUpdate": health?["lastAutoUpdate"].flatMap { last -> JSONValue? in
                        guard let ok = last["ok"]?.boolValue else { return nil }
                        return ["ok": .bool(ok), "detail": .string(last["detail"]?.stringValue ?? "")]
                    } ?? .null,
                ]
            }),
        ]
    }

    /// Reads the daemon's harnesses again, and their health (`recheck`: the daemon checks again
    /// instead of answering its last check). Only the newest read writes the rows.
    func refresh(recheck: Bool = false) async {
        await refreshUpdates?()
        guard let environment = environment() else {
            rows = []
            problem = "unavailable"
            return
        }
        generation += 1
        let mine = generation
        loading = true
        let fresh: [AcpmuxHarnessRow]?
        do { fresh = try await fetch(environment) } catch { fresh = nil }
        guard mine == generation else { return }
        loading = false
        guard let fresh else {
            problem = "unreachable"
            return
        }
        rows = fresh
        problem = nil
        // The rows show first: a check can take a while. A failed one (an older daemon without
        // the method, a timeout) keeps the health already shown.
        guard let checked = try? await fetchHealth(environment, recheck),
              mine == generation, let read = AgentCLIUpdateActions.healthRows(checked) else { return }
        health = read
    }

    /// Types `line` into a new terminal tab; refuses a line that could not be typed safely.
    private func type(_ line: String?) throws {
        guard let line else { throw PageError.invalidParams("this acpmux path cannot be typed into a shell") }
        openTerminal(line)
    }

    /// One page gesture (`cmux.settings.harnesses.run`): `refresh` (`recheck`: the daemon checks
    /// health again), `signIn` / `check` / `update` with a listed harness `id`, `updateAll`,
    /// `resumeUpdate` / `dismissUpdate` with a retained `intent` key, or `registry`.
    func run(_ params: JSONValue, context: PageCallContext?) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        // Anything that runs an update (now, or after acpmux's next check) or settles one needs the person.
        let updates = ["update", "updateAll", "resumeUpdate", "dismissUpdate"].contains(action) || (action == "autoUpdate" && params["on"]?.boolValue == true)
        guard !updates || context?.userGesture == true || context?.isConfirmedUser == true else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
        switch action {
        case "refresh":
            await refresh(recheck: params["recheck"]?.boolValue ?? false)
        case "update", "updateAll", "resumeUpdate", "dismissUpdate":
            guard action != "update" || rows.contains(where: { $0.id == params["id"]?.stringValue }) else { throw PageError.invalidParams("id must be a listed harness") }
            guard let runUpdate, let context else { throw PageError.unavailable(AgentHarnessStrings.unsupported) }
            return try await runUpdate(params, context)
        case "autoUpdate":
            // acpmux keeps the choice and runs the update after a check finds it outdated.
            guard let id = params["id"]?.stringValue, rows.contains(where: { $0.id == id }), let on = params["on"]?.boolValue else {
                throw PageError.invalidParams("autoUpdate needs a listed harness id and on")
            }
            guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
            let answer = try await environment.harness(.health, params: ["autoUpdate": ["id": id, "on": on] as [String: any Sendable]])
            if let read = AgentCLIUpdateActions.healthRows(answer) { health = read }
        case "signIn", "check":
            guard let id = params["id"]?.stringValue, rows.contains(where: { $0.id == id && $0.kind != "terminal" }) else { throw PageError.invalidParams("id must be a listed harness") }
            guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
            // `--`: an id is never taken for a flag.
            try type(environment.shellLine(["harness", "login"] + (action == "check" ? ["--status"] : []) + ["--", id]))
        case "registry":
            guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
            try type(environment.shellLine(["harness", "registry"]))
        default:
            throw PageError.invalidParams("unknown harnesses action \(action)")
        }
        return .object([:])
    }
}
