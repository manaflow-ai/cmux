/// `GET /v1/selfhost/info` of a self-hosted `cmux-chat-server`:
/// `{kind: "selfhost", user_id, login, display_name, server_name}`. The user
/// id is who the server takes the caller to be (from Tailscale WhoIs).
public struct HomeWireSelfHostInfo: Hashable, Sendable {
    /// The caller's participant id on this server (`user_ts_...`).
    public var userID: String
    /// The caller's Tailscale login.
    public var login: String
    /// The caller's name as Tailscale knows it.
    public var displayName: String
    /// The server's own name, for Settings.
    public var serverName: String

    public init(userID: String, login: String, displayName: String, serverName: String) {
        self.userID = userID
        self.login = login
        self.displayName = displayName
        self.serverName = serverName
    }

    /// The info in a reply body; nil when it is not a self-hosted server's.
    init?(_ body: HomeWireJSON) {
        let value = body["value"].object != nil ? body["value"] : body
        guard value["kind"].string == "selfhost", let user = value["user_id"].string, !user.isEmpty else { return nil }
        self.init(userID: user, login: value["login"].string ?? "",
                  displayName: value["display_name"].string ?? value["login"].string ?? "",
                  serverName: value["server_name"].string ?? "")
    }
}
