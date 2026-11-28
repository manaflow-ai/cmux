public import CmuxNextActions
import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The App's entry points into the GitHub connection: the `accounts.githubConnect` action and the
/// Accounts part of the Settings page. The App only binds them (code-quality.md SW14).
extension GitHubConnections {
    /// The `accounts.githubConnect` result: connect, then report the page's outcome and detail.
    /// A chat's Connect GitHub card (webviews githubConnect.ts) names the failed call's `repo` and
    /// the chat's link (`returnTo`), both checked by the pane (AgentPaneRequest+Decoding.swift): the
    /// person stays in the chat and GitHub's return comes back to it (``connect(repo:returnTo:)``).
    /// Without a repository (the palette, Settings, `cmux accounts github-connect`) the App opens
    /// Settings > Accounts first, as before.
    public func connectResult(_ invocation: ActionInvocation? = nil) async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        await connect(repo: invocation?["repo"]?.stringValue, org: invocation?["org"]?.stringValue, returnTo: invocation?["returnTo"]?.stringValue)
        let state = pageState
        let detail = state["detail"]?.stringValue ?? ""
        if error { return .failure(ActionWorkFailure(detail)) }
        return .success(["status": .string(state["outcome"]?.stringValue ?? "needs-action"), "detail": .string(detail)])
    }

    /// The Accounts part of the Settings page: the state of ACCOUNTS with this connection's under "github"
    /// and the active team's shared agent keys under "agentKeys".
    /// `signIn`: the daemon's sign-in accounts under "signInAccounts" (SettingsHarnesses+AccountSignIn.swift).
    public func accountsPageState(_ accounts: AccountsModel, agentKeys: TeamAgentKeys? = nil, signIn: SettingsHarnesses? = nil) -> JSONValue {
        guard let encoded = try? JSONValue.parse(JSONEncoder().encode(accounts.pageState)), case .object(var state) = encoded else { return .null }
        state["github"] = pageState
        if let agentKeys { state["agentKeys"] = agentKeys.pageState }
        if let signIn { state["signInAccounts"] = signIn.signInAccountsState }
        return .object(state)
    }

    /// The Accounts part's state and gesture runner as the Settings page host binds them.
    public func accountsPage(_ accounts: AccountsModel, agentKeys: TeamAgentKeys, signIn: SettingsHarnesses? = nil) -> (state: (@MainActor () -> JSONValue)?, run: (@MainActor (JSONValue) async throws -> JSONValue)?) {
        ({ self.accountsPageState(accounts, agentKeys: agentKeys, signIn: signIn) },
         { params in try await self.runAccountsPage(params, accounts: accounts, agentKeys: agentKeys, signIn: signIn) })
    }

    /// One gesture of the Accounts part of the Settings page: a GitHub or team agent key gesture here,
    /// any other through ACCOUNTS. Refresh, focus and a team switch also reload the GitHub list and the
    /// team's agent keys. `agentKeySave` takes the agent as `provider`, the kind as `name` and the pasted
    /// key as `secret`, which goes to the owner API once and is never kept.
    /// The in-place sign-in's gestures go to `signIn` (the daemon's `_acpmux/account/*`).
    public func runAccountsPage(_ params: JSONValue, accounts: AccountsModel, agentKeys: TeamAgentKeys? = nil,
                                signIn: SettingsHarnesses? = nil) async throws -> JSONValue {
        let gesture = params["action"]?.stringValue ?? ""
        if let signIn, let reply = try await signIn.runSignIn(gesture, params) { return reply }
        if gesture.hasPrefix("agentKey") {
            guard let agentKeys, ["agentKeySave", "agentKeyRemove", "agentKeyRefresh"].contains(gesture) else { throw PageError.invalidParams("unknown agent key action") }
            let agent = params["provider"]?.stringValue ?? ""
            switch gesture {
            case "agentKeySave": await agentKeys.save(agent: agent, kind: params["name"]?.stringValue ?? "", secret: params["secret"]?.stringValue ?? "")
            case "agentKeyRemove": await agentKeys.remove(agent: agent)
            default: await agentKeys.refresh()
            }
            return .object([:])
        }
        if gesture.hasPrefix("github") {
            guard ["githubConnect", "githubDisconnect", "githubReconfigure", "githubRefresh"].contains(gesture) else { throw PageError.invalidParams("unknown GitHub action") }
            if gesture == "githubConnect" { await connect() }
            else { await perform(gesture, connection: params["account"]?.stringValue) }
            return .object([:])
        }
        guard let action = AccountsPageAction(field: { params[$0]?.stringValue }) else {
            throw PageError.invalidParams("unknown accounts action")
        }
        if let error = await accounts.perform(action) { return ["error": .string(error)] }
        if ["refresh", "focus", "selectTeam"].contains(gesture) {
            await perform("githubRefresh")
            await agentKeys?.refresh()
            await signIn?.accountsPageRead(gesture)
        }
        return .object([:])
    }
}
