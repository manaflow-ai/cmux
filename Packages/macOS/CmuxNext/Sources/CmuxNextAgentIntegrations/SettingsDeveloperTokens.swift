public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
public import Observation
import CmuxNextCompat

/// Settings > Developer: cmux API tokens (cmux platform `/v1/tokens`), from the bundled
/// `cmux token list --json` (and `cmux token github list --json` for a person who may manage the
/// team's). New Token, Revoke, Allow Repository and Remove run `cmux token ...`, only on the
/// person's click. The CLI owns every request, the bearer, the team and every refusal (cmux-tui
/// `cli/token.rs`): this type only relays.
///
/// A new token is the one secret here: `create` answers it to the page that clicked, once, and
/// this type keeps no copy (never in `state`, a log or the next answer), so only that page holds it
/// until the person's Done.
///
/// Leo, 2026-11-25: "Should we be offering tokens/api keys for people to be accessing our stuff
/// with?" and "Convienient beats all. Just make good ui for it so people flow."
@MainActor
@Observable
public final class SettingsDeveloperTokens: PageProvider {
    public static let stateOp = "cmux.settings.tokens.state"
    public static let runOp = "cmux.settings.tokens.run"

    /// The CLI's list, as it printed it (webviews/src/pages/settings/ops.ts `DeveloperTokensState`).
    private(set) var list: JSONValue = .null
    private(set) var githubRules: JSONValue = .null
    private(set) var loading = false
    /// `unavailable` (no bundled cmux CLI) or `failed` (the list did not answer).
    private(set) var problem: String?
    /// The last action's refusal, in the CLI's words.
    private(set) var lastError: (action: String, code: String, message: String)?

    @ObservationIgnored private let cli: @MainActor () async -> URL?
    @ObservationIgnored private let runCLI: @Sendable (URL, [String], Data?) async throws -> (Int32, Data, Data)
    @ObservationIgnored private var generation = 0

    public init(cli: @escaping @MainActor () async -> URL?,
                runCLI: @escaping @Sendable (URL, [String], Data?) async throws -> (Int32, Data, Data) = SettingsIntegrationsHub.run) {
        self.cli = cli
        self.runCLI = runCLI
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp: return state
        case Self.runOp: return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `cmux.settings.tokens.state`.
    var state: JSONValue {
        let canManage = list["canManageTeamTokens"]?.boolValue == true
        return [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "listError": problem == "failed" ? (list["error"] ?? .null) : .null,
            "platform": list["platform"] ?? .null,
            "team": list["team"] ?? .null,
            "tokens": list["tokens"] ?? .array([]),
            "canManageTeamTokens": .bool(canManage),
            "githubRules": canManage ? (githubRules["rules"] ?? .null) : .null,
            "error": lastError.map { ["action": .string($0.action), "code": .string($0.code), "message": .string($0.message)] } ?? .null,
        ]
    }

    /// One gesture: `refresh`; `create` with a new token's fields; `revoke` with a listed token `id`;
    /// `allowRepository` with a rule's fields; `removeRepository` with a listed rule `id`. Only
    /// refresh runs without the person's click.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        if action == "refresh" {
            await refresh()
            return .object([:])
        }
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
        }
        let words = try Self.arguments(action: action, params: params, list: list, rules: githubRules)
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no bundled cmux CLI") }
        let reply = try? await awaitConcurrently({ try await runCLI(cli, ["token"] + words + ["--json"], nil) })
        let answer = reply.flatMap { SettingsIntegrationsHub.lastLine($0.1) }
        var created: JSONValue = .null
        if let answer, answer["ok"]?.boolValue == true {
            lastError = nil
            if action == "create", let token = answer["token"]?.stringValue, token.hasPrefix("cmux_pat_") {
                created = ["token": .string(token), "tokenInfo": answer["tokenInfo"] ?? .null]
            }
        } else {
            lastError = (action,
                         answer?["error"]?["code"]?.stringValue ?? "cli.failed",
                         answer?["error"]?["message"]?.stringValue ?? "")
        }
        await refresh()
        return created == .null ? ["ok": .bool(lastError == nil)] : ["ok": .bool(true), "created": created]
    }

    /// The ids the list named under `key` of `value`.
    nonisolated static func listed(_ value: JSONValue, _ key: String) -> Set<String> {
        Set((value[key]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
    }

    /// The scopes a gesture names, each one of the three, at least one.
    nonisolated static func scopes(_ params: JSONValue) throws -> [String] {
        let known = ["machines", "chats", "usage"]
        let named = (params["scopes"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !named.isEmpty, named.allSatisfy(known.contains) else {
            throw PageError.invalidParams("scopes are machines, chats or usage, at least one")
        }
        return known.filter(named.contains)
    }

    /// A free-text value as one `--flag=value` word: trimmed, one line, at most `limit` characters.
    nonisolated static func text(_ params: JSONValue, _ key: String, limit: Int) -> String? {
        guard let value = params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= limit, !value.contains(where: \.isNewline) else { return nil }
        return value
    }

    /// The CLI words (after `token`) for one action. Every id is one the page was shown, and every
    /// value goes as `--flag=value`, so a page script cannot pass flags of its own.
    nonisolated static func arguments(action: String, params: JSONValue, list: JSONValue, rules: JSONValue) throws -> [String] {
        let id = params["id"]?.stringValue ?? ""
        switch action {
        case "create":
            guard let name = text(params, "name", limit: 64) else { throw PageError.invalidParams("name is 1 to 64 characters") }
            var words = ["create", "--name=\(name)"]
            words += try scopes(params).map { "--scope=\($0)" }
            switch params["expiresInDays"] {
            case .some(.null): words.append("--expires-days=never")
            case let value?:
                guard let days = value.doubleValue, days >= 1, days <= 365, days == days.rounded() else {
                    throw PageError.invalidParams("expiresInDays is 1 to 365, or null")
                }
                words.append("--expires-days=\(Int(days))")
            case nil: break
            }
            if let cap = params["spendCapUsd"]?.doubleValue {
                guard cap > 0, cap.isFinite else { throw PageError.invalidParams("spendCapUsd is above 0") }
                words.append("--spend-cap=\(cap)")
            }
            let owner = params["owner"]?.stringValue ?? "me"
            guard owner == "me" || (owner == "team" && list["canManageTeamTokens"]?.boolValue == true) else {
                throw PageError.invalidParams("owner is me, or team for a team admin")
            }
            words.append("--owner=\(owner)")
            return words
        case "revoke":
            guard listed(list, "tokens").contains(id) else { throw PageError.invalidParams("id must be a listed token") }
            return ["revoke", id]
        case "allowRepository":
            guard list["canManageTeamTokens"]?.boolValue == true else { throw PageError.invalidParams("only a team admin allows a repository") }
            guard let repository = text(params, "repository", limit: 140),
                  repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil else {
                throw PageError.invalidParams("repository is owner/name")
            }
            var words = ["github", "allow", "--repository=\(repository)"]
            if let ref = text(params, "ref", limit: 255) { words.append("--ref=\(ref)") }
            if let environment = text(params, "environment", limit: 255) { words.append("--environment=\(environment)") }
            words += try scopes(params).map { "--scope=\($0)" }
            return words
        case "removeRepository":
            guard listed(rules, "rules").contains(id) else { throw PageError.invalidParams("id must be a listed repository") }
            return ["github", "remove", id]
        default:
            throw PageError.invalidParams("unknown action \(action)")
        }
    }

    /// Reads the list again (and the GitHub rules for a team admin); only the newest read writes it.
    public func refresh() async {
        generation += 1
        let mine = generation
        loading = true
        guard let cli = await cli() else {
            list = .null
            githubRules = .null
            loading = false
            problem = "unavailable"
            return
        }
        let reply = try? await awaitConcurrently({ try await runCLI(cli, ["token", "list", "--json"], nil) })
        guard mine == generation else { return }
        guard let reply, let value = SettingsIntegrationsHub.lastLine(reply.1) else {
            loading = false
            problem = "failed"
            return
        }
        list = value
        problem = value["ok"]?.boolValue == true ? nil : "failed"
        if problem == nil, value["canManageTeamTokens"]?.boolValue == true {
            let rules = try? await awaitConcurrently({ try await runCLI(cli, ["token", "github", "list", "--json"], nil) })
            guard mine == generation else { return }
            let read = rules.flatMap { SettingsIntegrationsHub.lastLine($0.1) }
            githubRules = read?["ok"]?.boolValue == true ? (read ?? .null) : .null
        } else {
            githubRules = .null
        }
        loading = false
    }
}
