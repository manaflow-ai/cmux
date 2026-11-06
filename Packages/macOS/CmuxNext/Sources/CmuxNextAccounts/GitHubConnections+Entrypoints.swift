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

    /// The Accounts part of the Settings page: the state of ACCOUNTS with this connection's under "github".
    public func accountsPageState(_ accounts: AccountsModel) -> JSONValue {
        guard let encoded = try? JSONValue.parse(JSONEncoder().encode(accounts.pageState)), case .object(var state) = encoded else { return .null }
        state["github"] = pageState
        return .object(state)
    }

    /// One gesture of the Accounts part of the Settings page: a GitHub gesture here, any other
    /// through ACCOUNTS. Refresh, focus and a team switch also reload the GitHub list.
    public func runAccountsPage(_ params: JSONValue, accounts: AccountsModel) async throws -> JSONValue {
        let gesture = params["action"]?.stringValue ?? ""
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
        if ["refresh", "focus", "selectTeam"].contains(gesture) { await perform("githubRefresh") }
        return .object([:])
    }
}
