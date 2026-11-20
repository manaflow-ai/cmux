public import CmuxNextAgentPane
import CmuxNextAgentUpdates
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
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
public final class SettingsHarnesses {
    private(set) var rows: [AcpmuxHarnessRow] = []
    /// `_acpmux/harness/health` rows by harness id; empty from a daemon without it.
    private(set) var health: [String: JSONValue] = [:]
    /// Whether `health` is a check's answer: an answer can hold no row for a harness, which then
    /// was not found; with none (an older daemon, a failed recheck) every harness's state is unknown.
    private(set) var healthAnswered = false
    /// Whether `rows` is the daemon's last answer to `_acpmux/harnesses`: without one, a harness
    /// with no row is not known to be missing.
    private(set) var listAnswered = false
    private(set) var loading = false
    /// `unavailable` (no acpmux here) or `unreachable` (the daemon did not answer).
    private(set) var problem: String?
    /// `_acpmux/accounts` (SettingsHarnesses+Accounts.swift); nil from a daemon without it.
    var accounts: [SettingsProviderAccount]?
    /// Each account's plan usage limits read at rest, by id (SettingsHarnesses+AccountUsage.swift).
    var accountUsage: [String: JSONValue] = [:]
    /// Accounts whose usage read is running: a refresh meanwhile starts no second Codex for one.
    @ObservationIgnored var usageReading: Set<String> = []
    /// Accounts whose sign-in or sign-out was typed into a terminal tab: Settings coming forward reads
    /// them back (`focus`), as Accounts does for its logins.
    @ObservationIgnored var pendingLogins: Set<String> = []
    /// Reads of the accounts that answered (`readAccounts`): `refocused` keeps its marks until one does.
    @ObservationIgnored var accountsRead = 0
    /// Claude logins' plans by account id, from `claude auth status` (SettingsHarnesses+ClaudePlan.swift).
    var claudePlans: [String: String] = [:]
    @ObservationIgnored let environment: @MainActor () -> AcpmuxEnvironment?
    @ObservationIgnored private let fetch: @Sendable (AcpmuxEnvironment) async throws -> [AcpmuxHarnessRow]
    @ObservationIgnored private let fetchHealth: @Sendable (AcpmuxEnvironment, Bool) async throws -> Data
    /// Types a line into a new terminal tab on this Mac; false when no tab opened.
    @ObservationIgnored let openTerminal: @MainActor (String) async -> Bool
    @ObservationIgnored private let runUpdate: (@MainActor (JSONValue, PageCallContext) async throws -> JSONValue)?
    @ObservationIgnored private let updateState: @MainActor () -> JSONValue
    @ObservationIgnored private let refreshUpdates: (@MainActor () async -> Void)?
    /// A test's stand-in for the daemon's accounts calls; nil calls the daemon (`callAccounts`).
    @ObservationIgnored let accountsCall: (@Sendable (AcpmuxEnvironment, AcpmuxHarnessMethod, [String: any Sendable]) async throws -> Data)?
    /// A test's stand-in for `claude auth status --json` (the program, the login folder); nil runs it.
    @ObservationIgnored let claudeStatus: (@Sendable (String, String?) async -> Data?)?
    /// The person's home: an added account's folder is ~/.cmux/accounts/<id>, and the page shows folders under `~`.
    @ObservationIgnored let userHome: URL
    @ObservationIgnored private(set) var generation = 0
    /// The refusal text when this app cannot run updates (the App's localized string).
    @ObservationIgnored private let unsupported: (@MainActor () -> String)?

    public init(environment: @escaping @MainActor () -> AcpmuxEnvironment?,
         // nil, resolved below: an async function as a default argument is compiled again into every
         // calling module under one symbol name with a different async context size (cx-bsue); the
         // linker paired them and readHealth's free aborted the process ("freed pointer was not the
         // last allocation", macOS 27 minis).
         fetch: (@Sendable (AcpmuxEnvironment) async throws -> [AcpmuxHarnessRow])? = nil,
         fetchHealth: (@Sendable (AcpmuxEnvironment, Bool) async throws -> Data)? = nil,
         openTerminal: @escaping @MainActor (String) async -> Bool,
         runUpdate: (@MainActor (JSONValue, PageCallContext) async throws -> JSONValue)? = nil,
         updateState: @escaping @MainActor () -> JSONValue = { .array([]) },
         refreshUpdates: (@MainActor () async -> Void)? = nil,
         accountsCall: (@Sendable (AcpmuxEnvironment, AcpmuxHarnessMethod, [String: any Sendable]) async throws -> Data)? = nil,
         claudeStatus: (@Sendable (String, String?) async -> Data?)? = nil,
         userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         unsupported: (@MainActor () -> String)? = nil) {
        self.environment = environment
        self.fetch = fetch ?? { try await AcpmuxEnvironment.settingsHarnessRows($0) }
        self.fetchHealth = fetchHealth ?? { try await AcpmuxEnvironment.harnessHealth($0, refresh: $1) }
        self.openTerminal = openTerminal
        self.runUpdate = runUpdate
        self.updateState = updateState
        self.refreshUpdates = refreshUpdates
        self.accountsCall = accountsCall
        self.claudeStatus = claudeStatus
        self.userHome = userHome
        self.unsupported = unsupported
    }

    /// The page's `cmux.settings.harnesses.state` (webviews/src/pages/settings/ops.ts `HarnessesState`).
    public var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "jobs": updateState(),
            "accounts": accountsState,
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
                    // When acpmux last checked it (ms since the epoch): the page's "Checked 5m ago".
                    "checkedAt": health?["checkedAt"]?.doubleValue.map(JSONValue.number) ?? .null,
                    "lastAutoUpdate": health?["lastAutoUpdate"].flatMap { last -> JSONValue? in
                        guard let ok = last["ok"]?.boolValue else { return nil }
                        return ["ok": .bool(ok), "detail": .string(last["detail"]?.stringValue ?? "")]
                    } ?? .null,
                ]
            }),
        ]
    }

    /// Reads the daemon's harnesses again, and their health (`recheck`: the daemon checks again
    /// instead of answering its last check). Only the newest read writes the rows. `plans`: each
    /// Claude login's plan (`claude auth status`) and each account's usage; false for a health-only
    /// read (onboarding).
    func refresh(recheck: Bool = false, plans: Bool = true) async {
        await refreshUpdates?()
        // Before the guard: a read still running from an earlier refresh may not write over this one.
        generation += 1
        let mine = generation
        guard let environment = environment() else {
            rows = []
            listAnswered = false
            loading = false
            problem = "unavailable"
            return
        }
        loading = true
        let fresh: [AcpmuxHarnessRow]?
        do { fresh = try await fetch(environment) } catch { fresh = nil }
        guard mine == generation else { return }
        loading = false
        guard let fresh else {
            problem = "unreachable"
            listAnswered = false
            if recheck { forgetHealth() }
            return
        }
        rows = fresh
        listAnswered = true
        problem = nil
        // Accounts first: they answer from the daemon's state, a health check may take a while.
        await readAccounts(environment, generation: mine)
        guard mine == generation else { return }
        // Usage beside health: each starts a process of its own and either may take a while.
        // A health-only read (onboarding) runs neither usage nor `claude auth status`.
        guard plans else { return await readHealth(environment, recheck: recheck, plans: false, generation: mine) }
        async let usage: Void = readAccountUsage(environment, generation: mine)
        await readHealth(environment, recheck: recheck, plans: true, generation: mine)
        await usage
    }

    /// The rows show first: a check can take a while. A failed read (an older daemon without the
    /// method, a timeout) keeps the health already shown; a failed recheck clears it, so the states
    /// it would have replaced do not show as current.
    private func readHealth(_ environment: AcpmuxEnvironment, recheck: Bool, plans: Bool, generation mine: Int) async {
        let checked = try? await fetchHealth(environment, recheck)
        guard mine == generation else { return }
        guard let checked, let read = AgentCLIUpdateActions.healthRows(checked) else {
            if recheck { forgetHealth() }
            return
        }
        health = read
        healthAnswered = true
        // The health check names the `claude` it found; each Claude login's plan comes from it.
        if plans { await readClaudePlans(generation: mine) }
    }

    /// A recheck that got no answer: no sign-in state shows as current.
    private func forgetHealth() {
        health = [:]
        healthAnswered = false
    }

    /// Types `line` into a new terminal tab; refuses a line that could not be typed safely, and
    /// fails when no terminal tab opened.
    private func type(_ line: String?) async throws {
        guard let line else { throw PageError.invalidParams("this acpmux path cannot be typed into a shell") }
        try await typeLine(line)
    }

    /// `line` in a new terminal tab on this Mac; fails when none opened (no local pane, no daemon).
    func typeLine(_ line: String) async throws {
        guard await openTerminal(line) else { throw PageError.unavailable("no terminal tab could be opened on this Mac") }
    }

    /// One page gesture (`cmux.settings.harnesses.run`): `refresh` (`recheck`: the daemon checks
    /// health again), `signIn` / `check` / `update` with a listed harness `id`, `updateAll`,
    /// `resumeUpdate` / `dismissUpdate` with a retained `intent` key, or `registry`.
    public func run(_ params: JSONValue, context: PageCallContext?) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        // Anything that runs an update (now, or after acpmux's next check) or settles one needs the person.
        let updates = ["update", "updateAll", "resumeUpdate", "dismissUpdate"].contains(action) || (action == "autoUpdate" && params["on"]?.boolValue == true)
        guard !updates || context?.userGesture == true || context?.isConfirmedUser == true else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
        switch action {
        case "refresh":
            await refresh(recheck: params["recheck"]?.boolValue ?? false)
        case "focus":
            await refocused()
        case "update", "updateAll", "resumeUpdate", "dismissUpdate":
            guard action != "update" || rows.contains(where: { $0.id == params["id"]?.stringValue }) else { throw PageError.invalidParams("id must be a listed harness") }
            guard let runUpdate, let context else { throw PageError.unavailable(unsupported?() ?? "") }
            return try await runUpdate(params, context)
        case "autoUpdate":
            // acpmux keeps the choice and runs the update after a check finds it outdated.
            guard let id = params["id"]?.stringValue, rows.contains(where: { $0.id == id }), let on = params["on"]?.boolValue else {
                throw PageError.invalidParams("autoUpdate needs a listed harness id and on")
            }
            guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
            let answer = try await environment.harness(.health, params: ["autoUpdate": ["id": id, "on": on] as [String: any Sendable]])
            if let read = AgentCLIUpdateActions.healthRows(answer) {
                health = read
                healthAnswered = true
            }
        case "signIn", "check":
            guard let id = params["id"]?.stringValue, rows.contains(where: { $0.id == id && $0.kind != "terminal" }) else { throw PageError.invalidParams("id must be a listed harness") }
            guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
            // `--`: an id is never taken for a flag.
            try await type(environment.shellLine(["harness", "login"] + (action == "check" ? ["--status"] : []) + ["--", id]))
        case "accountEnable", "accountAdd", "accountSignIn", "accountSignOut", "accountRename", "accountDefault", "accountRemove":
            // A switch that lets routing move chats, a new login folder, or a sign-in: the person's.
            guard context?.userGesture == true || context?.isConfirmedUser == true else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            return try await runAccount(action, params)
        case "registry":
            guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
            try await type(environment.shellLine(["harness", "registry"]))
        default:
            throw PageError.invalidParams("unknown harnesses action \(action)")
        }
        return .object([:])
    }
}
