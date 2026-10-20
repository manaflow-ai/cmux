import CmuxInstallAuthCore
import Foundation
@testable import CmuxNextCloud

/// Session-only team listing beside an independent owner that checks the real Mac signer.
actor CloudTeamScopeWorld: InstallAuthTransport {
    let owner = MacTeamAuthOwner(user: NativeDeviceTestWorld.user)
    static let personal = "team_" + String(repeating: "c", count: 20)
    static let shared = NativeDeviceTestWorld.team("tenant_a")
    private var selected = CloudTeamScope.Selection(account: "stack_1", stackTeam: "tenant_a", generation: 0)
    private var mode = "valid"
    private var beforeReply: (@Sendable () async -> Void)?
    private var beforeOperationReply: (@Sendable () async -> Void)?
    private var authority = String(repeating: "a", count: 64)
    private var authorityMode = "valid"
    private(set) var authorityReads = 0
    private(set) var listings = 0
    private(set) var operationTeams: [String] = []

    func selection() -> CloudTeamScope.Selection { selected }
    func select(_ team: String?) {
        selected = .init(account: selected.account, stackTeam: team, generation: selected.generation + 1)
    }
    func setMode(_ value: String) { mode = value }
    func onReply(_ action: @escaping @Sendable () async -> Void) { beforeReply = action }
    func changeAuthority(_ value: String) { authority = value }
    func setAuthorityMode(_ value: String) { authorityMode = value }
    func onOperationReply(_ action: @escaping @Sendable () async -> Void) { beforeOperationReply = action }

    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let body = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        if body?["op"] as? String == "install.authority" {
            guard path == "/v1/read", let bearer, bearer != NativeDeviceTestWorld.session(),
                  let payload = bearer.split(separator: ".").dropFirst().first,
                  let data = Data(base64URLEncoded: String(payload)),
                  let claims = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let team = claims["team"], headers["x-cmux-team"] == team,
                  (body?["params"] as? [String: String])?.isEmpty == true else { throw MacTeamAuthOwner.Failure.invalidRequest }
            authorityReads += 1
            if authorityMode == "revoked" { return (403, Data(#"{"code":"auth.forbidden"}"#.utf8)) }
            var value: [String: Any] = ["user": claims["sub"]!, "install": claims["inst"]!, "grant": claims["grant"]!, "team": team, "authority_version": authority]
            if authorityMode == "missing" { value.removeValue(forKey: "authority_version") }
            if authorityMode == "null" { value["authority_version"] = NSNull() }
            if ["user", "team", "install", "grant"].contains(authorityMode) { value[authorityMode] = "other" }
            return (200, try JSONSerialization.data(withJSONObject: ["op": "install.authority", "value": value]))
        }
        if body?["op"] as? String == "feed.answer" {
            guard path == "/v1/ops", bearer == NativeDeviceTestWorld.session(), let team = headers["x-cmux-team"] else {
                throw MacTeamAuthOwner.Failure.invalidRequest
            }
            operationTeams.append(team)
            let action = beforeOperationReply; beforeOperationReply = nil
            await action?()
            return (200, Data(#"{"ok":true,"value":{}}"#.utf8))
        }
        guard body?["op"] as? String == "user.teams.list" else {
            return try await owner.post(path, json: json, bearer: bearer, headers: headers)
        }
        guard path == "/v1/read", bearer == NativeDeviceTestWorld.session(),
              body?["idempotency_key"] == nil, headers["x-cmux-team"] == nil else {
            throw MacTeamAuthOwner.Failure.invalidRequest
        }
        listings += 1
        var personal: [String: Any] = ["id": Self.personal, "kind": "personal", "sso_required": false]
        var shared: [String: Any] = ["id": Self.shared, "kind": "stack", "stack_team": "tenant_a", "sso_required": false]
        if mode == "wrong-personal" { personal["id"] = Self.shared }
        if mode == "sso" { shared["sso_required"] = true }
        if mode == "bad-id" { shared["id"] = "team_not-canonical" }
        if mode == "missing-reference" { shared.removeValue(forKey: "stack_team") }
        var teams = [personal, shared]
        if mode == "missing" || mode == "incomplete" { teams = [personal] }
        if mode == "duplicate" { teams.append(shared) }
        let action = beforeReply; beforeReply = nil
        await action?()
        return (200, try JSONSerialization.data(withJSONObject: ["op": "user.teams.list", "value": ["teams": teams, "incomplete": mode == "incomplete"]]))
    }
}
