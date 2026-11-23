import CmuxNextAgentPane
public import CmuxNextOnboarding
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
            // An older daemon: a start types the terminal sign-in here, inside the same call, while
            // the click still counts as the person's (a second page call after this round trip could
            // miss the host's one-second gesture window and do nothing). `terminal` tells the page
            // it ran, so the page runs no fallback of its own.
            if method == .accountSignIn {
                let (fallback, fallbackParams) = Self.terminalSignIn(params)
                _ = try await runAccount(fallback, fallbackParams)
                return ["terminal": true]
            }
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
            await readSignIns(environment)
            return ["finished": value]
        case .accountSignInCancel:
            return .object([:])
        default:
            await readSignIns(environment)
            return .object([:])
        }
    }

    /// Onboarding's two sign-in keys (`signInAccounts`, `signInReadiness`): both null until the daemon
    /// answers `_acpmux/account/readiness`, so with an older daemon onboarding is as before.
    public var onboardingSignInState: (accounts: JSONValue, readiness: JSONValue) {
        guard let signInReadiness else { return (.null, .null) }
        return (signInAccountsState, signInReadiness)
    }

    /// The Agents step's in-place sign-in over this forwarder (AgentSignInSource).
    public var onboardingSignIn: OnboardingSignIn? { .forwarding { [weak self] in self } }

    /// Reads the accounts and the providers' readiness again (onboarding's open and focus).
    public func refreshSignIns() async {
        guard let environment = environment() else { return }
        await readSignIns(environment)
    }

    /// The accounts, then `_acpmux/account/readiness` as the daemon sent it: method not found clears
    /// it, another failure keeps what is shown. The readiness is only read once a read answered it.
    private func readSignIns(_ environment: AcpmuxEnvironment) async {
        await readAccounts(environment, generation: generation)
        do {
            let data = try await callAccounts(environment, .accountReadiness, [:])
            if let value = try? JSONValue.parse(data) { signInReadiness = value }
        } catch let error as AcpmuxRPCError where error.isMethodMissing {
            signInReadiness = nil
        } catch {}
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

    /// A start's terminal sign-in for a daemon without `_acpmux/account/sign_in`, the Agents >
    /// Harnesses way (webviews `useSettingsSignIn.ts` `terminalSignIn`): a listed account's own login
    /// (`harness login -- <family>` with its folder), gh's `gh auth login` for GitHub, else a new
    /// login of the family with its typed name. Settings > Models' `connectClaude` makes the same pick.
    nonisolated static func terminalSignIn(_ params: JSONValue) -> (action: String, params: JSONValue) {
        let field = { (key: String) -> String? in params[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        let family = field("family") ?? field("provider") ?? ""
        if family != "github", let account = field("account") {
            return ("accountSignIn", ["account": .string(account)])
        }
        var add: [String: JSONValue] = ["family": .string(family), "way": "new"]
        if family != "github", let name = field("name") { add["name"] = .string(name) }
        return ("accountAdd", .object(add))
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

extension OnboardingSignIn {
    /// The Agents step's sign-in over `harnesses` (the App's own reader): the same forwarder, rows and
    /// page opener as Settings > Accounts. A gone reader answers null and refuses nothing it does not run.
    public static func forwarding(_ harnesses: @escaping @MainActor () -> SettingsHarnesses?) -> OnboardingSignIn {
        OnboardingSignIn(state: { harnesses()?.onboardingSignInState ?? (.null, .null) },
                         refresh: { await harnesses()?.refreshSignIns() },
                         run: { action, params in try await harnesses()?.runSignIn(action, params) })
    }
}
