import Foundation

extension CloudStartCore {
    /// The plan's request: the send's key, account and Mac workspace, who is signed in, the machines the account's list named (as the pick
    /// reads them), the store's others (`stored`: kept for a pin, never picked), and the chat's folder, environment and token flag (`access`).
    public func planRequest(key: String, account: [String?], workspace: String?, user: String?, machines: [[String: Any]],
                            local: String? = nil, stored: [String], environment: String? = nil, access: Bool = false,
                            reservationKey: String? = nil, platform: String? = nil, team: String? = nil, ensureProject: Bool? = nil) -> String {
        var request: [String: Any] = ["key": key, "account": accountText(account), "loaded": true, "machines": machines,
                                      "stored": stored, "credential_on_stdin": access]
        for (name, value) in [("user", user), ("workspace", workspace), ("local", local), ("environment", environment),
                              ("reservation_key", reservationKey), ("platform", platform), ("team", team)] { request[name] = value }
        request["ensure_project"] = ensureProject
        let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension CloudMachineRequest {
    /// The create of the machine for a send: sized for the chat, under the send's own idempotency key
    /// (the plan's `create_key`), so a retry after a create whose answer was lost gets the same
    /// machine from the server, never a second paid VM. Its team is the send's (`team`, the account's
    /// team when the send began), fixed for every try, so a team switch during a slow create never
    /// makes the machine in the other team.
    public init(startChatKey key: String, sizedFor pick: CloudWorkPick?, team: String?) {
        self.init()
        autosize = pick?.autosize
        idempotencyKey = key
        self.team = team
    }
}
