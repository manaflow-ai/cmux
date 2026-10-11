import CmuxNextAgentPane
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
/// sign-out the daemon has evidence for, and its update command. Update and Update all type that
/// command into a terminal tab the same way; an update that needs sudo is never typed (the page
/// shows the command). Refresh asks the daemon to check again, so a finished update shows.
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
    @ObservationIgnored private var generation = 0

    init(environment: @escaping @MainActor () -> AcpmuxEnvironment?,
         fetch: @escaping @Sendable (AcpmuxEnvironment) async throws -> [AcpmuxHarnessRow] = { try await $0.harnessRows() },
         fetchHealth: @escaping @Sendable (AcpmuxEnvironment, Bool) async throws -> Data = {
             try await $0.harness(.health, params: ["refresh": $1])
         },
         openTerminal: @escaping @MainActor (String) -> Void) {
        self.environment = environment
        self.fetch = fetch
        self.fetchHealth = fetchHealth
        self.openTerminal = openTerminal
    }

    /// The page's `cmux.settings.harnesses.state` (webviews/src/pages/settings/ops.ts `HarnessesState`).
    var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
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
                ]
            }),
        ]
    }

    /// Reads the daemon's harnesses again, and their health (`recheck`: the daemon checks again
    /// instead of answering its last check). Only the newest read writes the rows.
    func refresh(recheck: Bool = false) async {
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
        // An older daemon has no health method: the rows show without it.
        let checked = try? await fetchHealth(environment, recheck)
        guard mine == generation else { return }
        loading = false
        if let fresh {
            rows = fresh
            health = Self.healthRows(checked)
            problem = nil
        } else {
            problem = "unreachable"
        }
    }

    private static func healthRows(_ data: Data?) -> [String: JSONValue] {
        guard let data, let rows = (try? JSONValue.parse(data))?["harnesses"]?.arrayValue else { return [:] }
        return Dictionary(rows.compactMap { row in row["id"]?.stringValue.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The update a click may type for harness `id`: its daemon's argv, each word single-quoted;
    /// nil when it is not outdated, needs sudo, or holds a character no shell quotes alike.
    private func updateLine(_ id: String) -> String? {
        guard let row = health[id], row["outdated"]?.boolValue == true, let plan = row["update"],
              plan["elevated"]?.boolValue == false,
              let argv = plan["argv"]?.arrayValue?.compactMap(\.stringValue), !argv.isEmpty else { return nil }
        let unsafe: (Character) -> Bool = { character in
            character == "'" || character == "\\" || character.isNewline
                || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        guard !argv.contains(where: { $0.contains(where: unsafe) }) else { return nil }
        return argv.map { "'" + $0 + "'" }.joined(separator: " ")
    }

    /// Types `line` into a new terminal tab; refuses a line that could not be typed safely.
    private func type(_ line: String?) throws {
        guard let line else { throw PageError.invalidParams("this acpmux path cannot be typed into a shell") }
        openTerminal(line)
    }

    /// One page gesture (`cmux.settings.harnesses.run`): `refresh` (`recheck`: the daemon checks
    /// health again), `signIn` / `check` / `update` with a listed harness `id`, `updateAll`, or
    /// `registry`.
    func run(_ params: JSONValue) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        switch action {
        case "refresh":
            await refresh(recheck: params["recheck"]?.boolValue ?? false)
        case "update":
            guard let id = params["id"]?.stringValue, rows.contains(where: { $0.id == id }) else {
                throw PageError.invalidParams("id must be a listed harness")
            }
            try type(updateLine(id))
        case "updateAll":
            // Two harnesses from one package update once; each line runs whether the one before failed.
            var lines: [String] = []
            for row in rows { if let line = updateLine(row.id), !lines.contains(line) { lines.append(line) } }
            guard !lines.isEmpty else { throw PageError.invalidParams("no harness can be updated here") }
            openTerminal(lines.joined(separator: "; "))
        case "signIn", "check":
            guard let id = params["id"]?.stringValue, rows.contains(where: { $0.id == id && $0.kind != "terminal" }) else {
                throw PageError.invalidParams("id must be a listed harness")
            }
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
