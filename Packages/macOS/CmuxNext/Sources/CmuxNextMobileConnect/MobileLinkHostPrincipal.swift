public import Foundation

/// Who this Mac is on the control plane for the signed-in account
/// (b6-pairing.md section 2): the enrolled host id, the account's backend
/// user, this install, and the API it was minted against.
public struct MobileLinkHostPrincipal: Sendable, Hashable {
    /// `host_…`, the host this install enrolled (TeamDO `hostAccess`).
    public var hostID: String
    /// `user_…`, the backend user (not the Stack user id).
    public var accountUserID: String
    /// `inst_…`, this Mac's install.
    public var install: String
    /// The API environment certs are signed for (`production`, `staging`, …).
    public var environment: String
    /// The API Worker origin (`https://…`); sockets use `wss://` on it.
    public var apiBaseURL: URL

    public init(hostID: String, accountUserID: String, install: String, environment: String, apiBaseURL: URL) {
        self.hostID = hostID
        self.accountUserID = accountUserID
        self.install = install
        self.environment = environment
        self.apiBaseURL = apiBaseURL
    }
}
