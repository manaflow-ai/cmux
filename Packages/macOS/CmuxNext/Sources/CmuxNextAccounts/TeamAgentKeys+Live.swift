public import CmuxNextCloud
public import CmuxNextSettings
public import Foundation

extension TeamAgentKeys {
    /// The team keys of the Cloud sign-in AUTH's active team, through the owner API at OWNER_API
    /// (`v1/read` for the status, `v1/ops` with an idempotency key for a change). PREVIEW (showcase or
    /// fixture launches) is always signed out. The request body holds the key only for `team.agent_key.set`
    /// and is never logged; a failure reports the API's error code, never the request.
    public static func live(auth: CloudAuth, ownerAPI: URL, preview: Bool) -> TeamAgentKeys {
        let transport = InstallHTTPTransport(baseURL: ownerAPI)
        let current: @MainActor () -> Scope? = {
            guard !preview, auth.isSignedIn, let user = auth.user?.id else { return nil }
            return GitHubConnections.signedInScope(project: auth.configuration.stackProjectID, user: user, team: auth.teamID, managedTeam: auth.managedTeamID)
        }
        return TeamAgentKeys(scope: current, call: { bound, op, params, mutationKey in
            let access = try await auth.tokens().access
            guard current() == bound else { throw Failure.changedAccount }
            var body: [String: JSONValue] = ["op": .string(op), "params": params]
            if let mutationKey {
                body["origin"] = "user"
                body["idempotency_key"] = .string(mutationKey)
            }
            var headers: [String: String] = [:]
            if let team = GitHubConnections.backendTeam(project: auth.configuration.stackProjectID, stackTeam: bound.team) { headers["x-cmux-team"] = team }
            let response = try await transport.post(mutationKey != nil ? "v1/ops" : "v1/read", json: Data(JSONValue.object(body).compactText.utf8), bearer: access, headers: headers)
            guard current() == bound else { throw Failure.changedAccount }
            return try reply(status: response.status, body: response.body)
        })
    }

    /// The value of an owner API answer, or the refusal it carries. A timeout, throttling answer or
    /// server failure does not prove the change was refused (`owner.unreachable` keeps its key).
    public nonisolated static func reply(status: Int, body: Data) throws -> JSONValue {
        guard status < 500, status != 408, status != 429 else { throw Failure.refused("owner.unreachable") }
        let parsed = try? JSONValue.parse(body)
        if let code = parsed?["error"]?["code"]?.stringValue, !code.isEmpty { throw Failure.refused(code) }
        guard (200..<300).contains(status) else { throw Failure.refused(status == 403 ? "auth.forbidden" : "invalid_reply") }
        guard let parsed, parsed["ok"] != .bool(false), let value = parsed["value"] else { throw Failure.invalidReply }
        return value
    }
}
