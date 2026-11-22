import CmuxNextAgentPane
import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Settings > Accounts' in-place sign-in (logins done right; Leo, 2026-11-22: "we likewise want gh
/// auth or device stuff to be much more convienient ui/ux wise ... this is simply logins, done
/// righr."). The page's gestures (webviews `shared/signIn/accountSignIn.ts` `ACCOUNT_ACTIONS`) are
/// forwarded to acpmux's `_acpmux/account/*` (`server/account_sign_in.rs`), which owns every rule;
/// this only maps names, opens the page a start names, and keeps the terminal sign-in for a daemon
/// that has no such method. No code or token is kept, logged or put in the page state.
extension SettingsHarnesses {
    /// The page's sign-in gestures and the daemon methods they forward to; the one place the names meet.
    nonisolated static let signInMethods: [String: AcpmuxHarnessMethod] = [
        "signInStart": .accountSignIn,
        "signInFinish": .accountSignInFinish,
        "signInCancel": .accountSignInCancel,
        "accountSwitch": .accountSwitch,
        "accountRemove": .accountRemove,
        "accountSignOut": .accountSignOut,
    ]

    /// Settings > Accounts' gestures an older daemon (method not found) runs the Agents > Harnesses way.
    nonisolated static let signInFallbacks: [String: String] = [
        "accountSwitch": "accountDefault", "accountRemove": "accountRemove", "accountSignOut": "accountSignOut",
    ]

    /// `accounts.signInAccounts`: the sign-in rows of `_acpmux/accounts` (GitHub, ChatGPT, Claude; an
    /// API-key route is no sign-in), webviews `AccountRowWire`; null before a read answers.
    public var signInAccountsState: JSONValue {
        guard let accounts else { return .null }
        return .array(accounts.filter { !$0.key }.map { account in
            var row: [String: JSONValue] = [
                "id": .string(account.id), "family": .string(account.family), "name": .string(account.name),
                "signedIn": .bool(account.signedIn), "default": .bool(account.isDefault), "builtin": .bool(account.builtin),
            ]
            if let email = account.email { row["email"] = .string(email) }
            if let plan = claudePlans[account.id] ?? account.plan { row["plan"] = .string(plan) }
            return .object(row)
        })
    }

    /// Settings > Accounts' `refresh` reads the accounts again; `focus` only after a terminal hand-off.
    public func accountsPageRead(_ gesture: String) async {
        if gesture == "focus" { return await refocused() }
        guard gesture == "refresh", let environment = environment() else { return }
        await readAccounts(environment, generation: generation)
    }

    /// One sign-in gesture's answer for the page (`AccountsRunReply`): `signIn` for a start, `finished`
    /// for a finish, `reason` for a refusal. Nil when `action` is not one of ``signInMethods``.
    public func runSignIn(_ action: String, _ params: JSONValue) async throws -> JSONValue? {
        guard let method = Self.signInMethods[action] else { return nil }
        guard let environment = environment() else { return ["reason": "acpmux.unreachable"] }
        let reply: Data
        do {
            reply = try await callAccounts(environment, method, Self.signInParams(method, params))
        } catch let error as AcpmuxRPCError where error.isMethodMissing {
            // An older daemon: a start answers no sign-in, so the page types the terminal sign-in.
            guard let fallback = Self.signInFallbacks[action] else { return .object([:]) }
            return try await runAccount(fallback, params)
        } catch let error as AcpmuxRPCError {
            return ["reason": .string(error.name ?? "other")]
        }
        let value = (try? JSONValue.parse(reply)) ?? .object([:])
        switch method {
        case .accountSignIn:
            if let page = Self.signInPage(value) { await openSignInPage?(page) }
            return ["signIn": value]
        case .accountSignInFinish:
            await readAccounts(environment, generation: generation)
            return ["finished": value]
        case .accountSignInCancel:
            return .object([:])
        default:
            await readAccounts(environment, generation: generation)
            return .object([:])
        }
    }

    /// The daemon's params from the page's: a listed `account`, else a new one's `family` (and `name`).
    nonisolated static func signInParams(_ method: AcpmuxHarnessMethod, _ params: JSONValue) -> [String: any Sendable] {
        let field = { (key: String) -> String? in params[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        var out: [String: any Sendable] = [:]
        switch method {
        case .accountSignIn:
            if let account = field("account") { out["account"] = account } else {
                out["family"] = field("family") ?? field("provider") ?? ""
                if let name = field("name") { out["name"] = name }
            }
        case .accountSignInFinish:
            out["loginId"] = field("loginId") ?? ""
            if let code = field("code") { out["code"] = code }
        case .accountSignInCancel:
            out["loginId"] = field("loginId") ?? ""
        default:
            out["account"] = field("account") ?? ""
        }
        return out
    }

    /// The page a start opens beside the window: Claude's automatic page when it has one, else its
    /// link; only an https sign-in or device page (``SignInPage``), never one with a user or port.
    nonisolated static func signInPage(_ reply: JSONValue) -> URL? {
        guard let raw = reply["autoUrl"]?.stringValue ?? reply["url"]?.stringValue, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              SignInPage(url: url) != nil else { return nil }
        return url
    }
}
