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
@MainActor
@Observable
final class SettingsHarnesses {
    private(set) var rows: [AcpmuxHarnessRow] = []
    private(set) var loading = false
    /// `unavailable` (no acpmux here) or `unreachable` (the daemon did not answer).
    private(set) var problem: String?
    @ObservationIgnored private let environment: @MainActor () -> AcpmuxEnvironment?
    @ObservationIgnored private let fetch: @Sendable (AcpmuxEnvironment) async throws -> [AcpmuxHarnessRow]
    @ObservationIgnored private let openTerminal: @MainActor (String) -> Void

    init(environment: @escaping @MainActor () -> AcpmuxEnvironment?,
         fetch: @escaping @Sendable (AcpmuxEnvironment) async throws -> [AcpmuxHarnessRow] = { try await $0.harnessRows() },
         openTerminal: @escaping @MainActor (String) -> Void) {
        self.environment = environment
        self.fetch = fetch
        self.openTerminal = openTerminal
    }

    /// The page's `cmux.settings.harnesses.state` (webviews/src/pages/settings/ops.ts `HarnessesState`).
    var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "harnesses": .array(rows.map { row in
                [
                    "id": .string(row.id), "name": row.name.map(JSONValue.string) ?? .null, "kind": .string(row.kind),
                    "source": .string(row.source), "problem": row.problem.map(JSONValue.string) ?? .null,
                ]
            }),
        ]
    }

    /// Reads the daemon's harnesses again.
    func refresh() async {
        _ = (environment, fetch) // red
    }

    /// One page gesture (`cmux.settings.harnesses.run`): `refresh`, `signIn` / `check` with a
    /// listed harness `id`, or `registry`.
    func run(_ params: JSONValue) async throws -> JSONValue {
        _ = openTerminal // red
        return .object([:])
    }
}
