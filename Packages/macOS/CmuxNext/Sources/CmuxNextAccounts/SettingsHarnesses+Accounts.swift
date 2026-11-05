public import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
public import Foundation

/// One provider account routing may use, from acpmux's `_acpmux/accounts`: the CLI's own login
/// (`builtin`, home nil) or an account the person added in a shadow home of its own.
nonisolated struct SettingsProviderAccount: Equatable, Sendable {
    let id: String
    let family: String
    let name: String
    /// The absolute login folder; nil is the CLI's default (`~/.codex`, `~/.claude`).
    let home: String?
    let shadowOf: String?
    let signedIn: Bool
    let plan: String?
    let email: String?
    let enabled: Bool
    let builtin: Bool
    /// New chats of its family run on it (acpmux: the family binding, else the global one, else the CLI login).
    let isDefault: Bool
    /// An API-key route: no login folder, no sign-in or sign-out.
    let key: Bool

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue, !id.isEmpty, let family = value["family"]?.stringValue else { return nil }
        self.id = id
        self.family = family
        name = value["name"]?.stringValue ?? id
        home = value["home"]?.stringValue
        shadowOf = value["shadowOf"]?.stringValue
        signedIn = value["signedIn"]?.boolValue ?? false
        plan = value["plan"]?.stringValue
        email = value["email"]?.stringValue
        enabled = value["enabled"]?.boolValue ?? false
        builtin = value["builtin"]?.boolValue ?? false
        isDefault = value["default"]?.boolValue ?? false
        key = value["key"]?.boolValue ?? false
    }

    /// The accounts of an `_acpmux/accounts` reply; nil when it carries no list.
    static func list(_ data: Data) -> [SettingsProviderAccount]? {
        guard let rows = (try? JSONValue.parse(data))?["accounts"]?.arrayValue else { return nil }
        return rows.compactMap(SettingsProviderAccount.init)
    }

    /// The CLI's default login folder of a family, as the page shows it.
    static func defaultHome(_ family: String) -> String? {
        switch family {
        case "codex": "~/.codex"
        case "claude": "~/.claude"
        default: nil
        }
    }

    /// The environment variable that points a family's CLI at another login folder
    /// (acpmux `route_account::home_var`).
    static func homeVariable(_ family: String) -> String? {
        switch family {
        case "codex": "CODEX_HOME"
        case "claude": "CLAUDE_CONFIG_DIR"
        default: nil
        }
    }

    /// The page's row: folders shown under `~`. The page never sends a folder back; actions name the id.
    func pageValue(userHome: String) -> JSONValue {
        let tilde = { (path: String) -> String in
            path == userHome ? "~" : path.hasPrefix(userHome + "/") ? "~" + path.dropFirst(userHome.count) : path
        }
        return [
            "id": .string(id), "family": .string(family), "name": .string(name),
            "home": home.map { .string(tilde($0)) } ?? .null,
            "defaultHome": Self.defaultHome(family).map(JSONValue.string) ?? .null,
            "shadowOf": shadowOf.map { .string(tilde($0)) } ?? .null,
            "signedIn": .bool(signedIn), "plan": plan.map(JSONValue.string) ?? .null,
            // Only this local Settings page shows the address; it is never logged or sent on.
            "email": email.map(JSONValue.string) ?? .null,
            "enabled": .bool(enabled), "builtin": .bool(builtin),
            "default": .bool(isDefault), "key": .bool(key),
        ]
    }
}

extension AcpmuxEnvironment {
    /// `harnessRows()` by name, so `SettingsHarnesses` can default to it without an async closure literal.
    public nonisolated static func settingsHarnessRows(_ environment: AcpmuxEnvironment) async throws -> [AcpmuxHarnessRow] {
        try await environment.harnessRows()
    }
}

extension SettingsHarnesses {
    /// One accounts call: the test's stand-in, else the local daemon. A direct call, not a static
    /// function reference as the init's default: that default crashed the suite (SIGSEGV entering it).
    func callAccounts(_ environment: AcpmuxEnvironment, _ method: AcpmuxHarnessMethod,
                      _ params: [String: any Sendable]) async throws -> Data {
        if let accountsCall { return try await accountsCall(environment, method, params) }
        return try await environment.harness(method, params: params)
    }

    /// The accounts the page lists; nil when the daemon has no `_acpmux/accounts` (the page then shows
    /// the harness rows alone, as before).
    var accountsState: JSONValue {
        guard let accounts else { return .null }
        let home = userHome.path
        return .array(accounts.map { $0.pageValue(userHome: home) })
    }

    /// Reads `_acpmux/accounts`; an older daemon (method not found) clears the list, another failure
    /// keeps what is shown. Only the newest refresh writes.
    func readAccounts(_ environment: AcpmuxEnvironment, generation mine: Int) async {
        do {
            let data = try await callAccounts(environment, .accounts, [:])
            guard mine == generation else { return }
            accounts = SettingsProviderAccount.list(data)
        } catch let error as AcpmuxRPCError where error.isMethodMissing {
            guard mine == generation else { return }
            accounts = nil
        } catch {}
    }

    /// The first id `<family>-<n>` (n from 2) no account has, and its name ("ChatGPT 2", "Claude 2").
    static func newAccount(family: String, existing: [SettingsProviderAccount]) -> (id: String, name: String) {
        let ids = Set(existing.map(\.id))
        let names = Set(existing.map(\.name))
        let base = family == "codex" ? "ChatGPT" : family == "claude" ? "Claude" : family
        var number = max(2, existing.filter { $0.family == family }.count + 1)
        while ids.contains("\(family)-\(number)") || names.contains("\(base) \(number)") { number += 1 }
        return ("\(family)-\(number)", "\(base) \(number)")
    }

    /// A listed account by the page's `account` id.
    private func listed(_ params: JSONValue, _ action: String) throws -> SettingsProviderAccount {
        guard let id = params["account"]?.stringValue, let account = accounts?.first(where: { $0.id == id }) else {
            throw PageError.invalidParams("\(action) needs a listed account")
        }
        return account
    }

    /// The page's account gestures (Leo, 2026-11-05: "i meant can you do all of htem": Settings gets the
    /// picker's add, default, rename and sign-out):
    /// - `accountEnable {account, on}`: routing may move chats onto it, or not.
    /// - `accountAdd {family, way, name?, secret?}`: `way` `new` makes a login folder of its own under
    ///   ~/.cmux/accounts (a shadow home for Codex), then types its sign-in; `key` adds an API-key route
    ///   whose `secret` is a reference (`keychain:NAME`, `env:VAR`, `file:/path`; acpmux refuses a raw key).
    /// - `accountSignIn {account}` and `accountSignOut {account}`: the CLI's own login or logout, in its folder.
    /// - `accountRename {account, name}`, `accountDefault {account}` (new chats of its family run on it) and
    ///   `accountRemove {account}` (acpmux keeps a backup of the route file; the login folder stays).
    /// The folder always comes from the daemon's own list or from here, never from the page.
    func runAccount(_ action: String, _ params: JSONValue) async throws -> JSONValue {
        guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
        switch action {
        case "accountEnable":
            guard let id = params["account"]?.stringValue, accounts?.contains(where: { $0.id == id }) == true,
                  let on = params["on"]?.boolValue else { throw PageError.invalidParams("accountEnable needs a listed account and on") }
            _ = try await callAccounts(environment, .accountSet, ["id": id, "enabled": on])
        case "accountAdd":
            guard let family = params["family"]?.stringValue, ["codex", "claude"].contains(family), let accounts else {
                throw PageError.invalidParams("accountAdd needs a family with accounts")
            }
            let made = Self.newAccount(family: family, existing: accounts)
            let typed = params["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = typed.isEmpty ? made.name : String(typed.prefix(128))
            if params["way"]?.stringValue == "key" {
                let secret = params["secret"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !secret.isEmpty, secret.utf8.count <= 4096 else {
                    throw PageError.invalidParams("an API-key account needs a secret reference")
                }
                _ = try await callAccounts(environment, .routeAdd, [
                    "id": made.id, "name": name, "kind": "direct-api-key", "families": [family], "secret": secret,
                ] as [String: any Sendable])
            } else {
                let home = userHome.appending(path: ".cmux/accounts/\(made.id)", directoryHint: .isDirectory).path
                var route: [String: any Sendable] = [
                    "id": made.id, "name": name, "kind": "direct-subscription", "families": [family], "accountHome": home,
                ]
                // A second ChatGPT login shares the CLI's conversations (route/add `shadow`), so routing can
                // move a chat onto it; a Claude login is a config folder of its own.
                if family == "codex" { route["shadow"] = true }
                _ = try await callAccounts(environment, .routeAdd, route)
                try signIn(family: family, home: home, environment: environment)
            }
        case "accountSignIn":
            let account = try listed(params, action)
            try signIn(family: account.family, home: account.home, environment: environment)
        case "accountSignOut":
            let account = try listed(params, action)
            guard !account.key, let line = Self.signOutLine(family: account.family, home: account.home) else {
                throw PageError.invalidParams("accountSignOut needs an account with a login")
            }
            openTerminal(line)
        case "accountRename":
            let account = try listed(params, action)
            let name = params["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name.count <= 128, account.id != "claude-login" else {
                throw PageError.invalidParams("accountRename needs a name and an account acpmux keeps a file for")
            }
            _ = try await callAccounts(environment, .accountSet, ["id": account.id, "name": name])
        case "accountDefault":
            let account = try listed(params, action)
            // The CLI's own login is the family's default with no binding.
            var bind: [String: any Sendable] = ["scope": "family:\(account.family)"]
            if !account.builtin { bind["routeId"] = account.id }
            _ = try await callAccounts(environment, .routeDefaultSet, bind)
        case "accountRemove":
            let account = try listed(params, action)
            guard !account.builtin else { throw PageError.invalidParams("the CLI's own login is not removed here") }
            _ = try await callAccounts(environment, .routeRemove, ["id": account.id])
        default:
            throw PageError.invalidParams("unknown harnesses action \(action)")
        }
        await refresh()
        return .object([:])
    }

    /// The CLI's own logout, in an added account's folder: `codex logout`, `claude auth logout`. Nil for a
    /// family with no logout or a folder that cannot be typed into a shell.
    static func signOutLine(family: String, home: String?) -> String? {
        let command: String
        switch family {
        case "codex": command = "codex logout"
        case "claude": command = "claude auth logout"
        default: return nil
        }
        guard let home else { return command }
        guard let variable = SettingsProviderAccount.homeVariable(family),
              !home.contains(where: { $0 == "'" || $0 == "\\" || $0.isNewline }) else { return nil }
        return "\(variable)='\(home)' \(command)"
    }

    /// `acpmux harness login -- <family>` in a new terminal tab, with the family's home variable set
    /// for an account in a folder of its own (acpmux `route_account::login_command`'s shape).
    private func signIn(family: String, home: String?, environment: AcpmuxEnvironment) throws {
        guard let line = environment.shellLine(["harness", "login", "--", family]) else {
            throw PageError.invalidParams("this acpmux path cannot be typed into a shell")
        }
        guard let home else { return openTerminal(line) }
        guard let variable = SettingsProviderAccount.homeVariable(family),
              !home.contains(where: { $0 == "'" || $0 == "\\" || $0.isNewline }) else {
            throw PageError.invalidParams("this account folder cannot be typed into a shell")
        }
        openTerminal("\(variable)='\(home)' " + line)
    }
}
