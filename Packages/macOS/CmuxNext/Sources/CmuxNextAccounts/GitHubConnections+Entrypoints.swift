public import CmuxNextActions
import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The App's entry points into the GitHub connection: the `accounts.githubConnect` action and the
/// Accounts part of the Settings page. The App only binds them (code-quality.md SW14).
extension GitHubConnections {
    /// The `accounts.githubConnect` result: connect, then report the page's outcome and detail.
    public func connectResult() async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        await connect()
        let state = pageState
        let detail = state["detail"]?.stringValue ?? ""
        if error { return .failure(ActionWorkFailure(detail)) }
        return .success(["status": .string(state["outcome"]?.stringValue ?? "needs-action"), "detail": .string(detail)])
    }

    /// The Accounts part of the Settings page: the state of ACCOUNTS with this connection's under "github"
    /// and the active team's shared agent keys under "agentKeys".
    public func accountsPageState(_ accounts: AccountsModel, agentKeys: TeamAgentKeys? = nil) -> JSONValue {
        guard let encoded = try? JSONValue.parse(JSONEncoder().encode(accounts.pageState)), case .object(var state) = encoded else { return .null }
        state["github"] = pageState
        if let agentKeys { state["agentKeys"] = agentKeys.pageState }
        return .object(state)
    }

    /// The Accounts part's state and gesture runner as the Settings page host binds them.
    public func accountsPage(_ accounts: AccountsModel, agentKeys: TeamAgentKeys) -> (state: (@MainActor () -> JSONValue)?, run: (@MainActor (JSONValue) async throws -> JSONValue)?) {
        ({ self.accountsPageState(accounts, agentKeys: agentKeys) }, { params in try await self.runAccountsPage(params, accounts: accounts, agentKeys: agentKeys) })
    }

    /// One gesture of the Accounts part of the Settings page: a GitHub or team agent key gesture here,
    /// any other through ACCOUNTS. Refresh, focus and a team switch also reload the GitHub list and the
    /// team's agent keys. `agentKeySave` takes the agent as `provider`, the kind as `name` and the pasted
    /// key as `secret`, which goes to the owner API once and is never kept.
    public func runAccountsPage(_ params: JSONValue, accounts: AccountsModel, agentKeys: TeamAgentKeys? = nil) async throws -> JSONValue {
        let gesture = params["action"]?.stringValue ?? ""
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
            guard ["githubConnect", "githubDisconnect", "githubRefresh"].contains(gesture) else { throw PageError.invalidParams("unknown GitHub action") }
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
        }
        return .object([:])
    }
}
