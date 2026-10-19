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
    private(set) var listings = 0

    func selection() -> CloudTeamScope.Selection { selected }
    func select(_ team: String?) {
        selected = .init(account: selected.account, stackTeam: team, generation: selected.generation + 1)
    }
    func setMode(_ value: String) { mode = value }
    func onReply(_ action: @escaping @Sendable () async -> Void) { beforeReply = action }

    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let body = try JSONSerialization.jsonObject(with: json) as? [String: Any]
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
