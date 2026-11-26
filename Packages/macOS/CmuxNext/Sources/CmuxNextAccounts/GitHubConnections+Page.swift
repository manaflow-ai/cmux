public import CmuxNextSettings
import CmuxNextDesign
import Foundation

extension GitHubConnections {
    public var pageState: JSONValue {
        let note: String
        if scopeIsSignedOut { note = Self.signIn }
        else if error { note = Self.failed }
        else if let linkRefusal, !connected { note = linkRefusal }
        else if pending { note = Self.pendingText }
        else if connected { note = Self.status("active") }
        else if !ready, !busy { note = Self.unavailable }
        else { note = Self.detail }
        return [
            "outcome": .string(scopeIsSignedOut ? "needs-action" : (error || (linkRefusal != nil && !connected)) ? "failed" : (pending || busy) ? "pending" : connected ? "connected" : "needs-action"),
            "title": "GitHub", "detail": .string(note), "busy": .bool(busy),
            "connect": .string(Self.connect), "disconnect": .string(Self.disconnect), "reconfigure": .string(Self.reconfigure),
            "confirm": .string(Self.confirm), "cancel": .string(Self.cancel),
            "refresh": .string(Self.refresh), "canConnect": .bool(canConnect),
            // Msg 3790: signed out, the card says to sign in and shows the Sign In button.
            "signIn": scopeIsSignedOut ? .string(SignInButton.defaultTitle) : .null,
            // Under it: what that Sign In signs in to ("Signs in to cmux.com").
            "signInBackend": scopeIsSignedOut ? signInBackend.map(JSONValue.string) ?? .null : .null,
            "connections": .array(currentConnections.map { row in
                ["id": row["id"] ?? .null,
                 "account": row["account"]?["name"] ?? "GitHub",
                 "status": .string(Self.status(row["status"]?.stringValue)),
                 "canDisconnect": .bool(canDisconnect(row)),
                 "canReconfigure": .bool(canReconfigure(row)),
                 "permissions": row["scopes_granted"] ?? .array([])]
            }),
        ]
    }
}

extension GitHubConnections {
    /// The words for a refused completion: the API's own `reason` when it gave one, else that the link expired.
    static func refusalWords(reason: String?) -> String { reason ?? linkExpired }
}

private extension GitHubConnections {
    static var connect: String { String(localized: "github.connect", defaultValue: "Connect GitHub", table: "GitHubConnection", bundle: .localizedModule) }
    static var disconnect: String { String(localized: "github.disconnect", defaultValue: "Disconnect", table: "GitHubConnection", bundle: .localizedModule) }
    static var reconfigure: String { String(localized: "github.reconfigure", defaultValue: "Reconfigure", table: "GitHubConnection", bundle: .localizedModule) }
    static var confirm: String { String(localized: "github.confirm", defaultValue: "Disconnect GitHub? Agents will lose access through this connection.", table: "GitHubConnection", bundle: .localizedModule) }
    static var cancel: String { String(localized: "github.cancel", defaultValue: "Cancel", table: "GitHubConnection", bundle: .localizedModule) }
    static var refresh: String { String(localized: "github.refresh", defaultValue: "Refresh", table: "GitHubConnection", bundle: .localizedModule) }
    static var detail: String { String(localized: "github.detail", defaultValue: "Connect the cmux GitHub App. Choose repositories and review permissions in GitHub.", table: "GitHubConnection", bundle: .localizedModule) }
    static var signIn: String { String(localized: "github.signIn", defaultValue: "Sign in to cmux to connect GitHub.", table: "GitHubConnection", bundle: .localizedModule) }
    static var unavailable: String { String(localized: "github.unavailable", defaultValue: "GitHub connections are unavailable on this deployment.", table: "GitHubConnection", bundle: .localizedModule) }
    static var pendingText: String { String(localized: "github.pending", defaultValue: "Finish connecting in your browser, then refresh.", table: "GitHubConnection", bundle: .localizedModule) }
    static var failed: String { String(localized: "github.failed", defaultValue: "GitHub could not be updated. Refresh to try again.", table: "GitHubConnection", bundle: .localizedModule) }
    static var reauth: String { String(localized: "github.reauth", defaultValue: "GitHub access was suspended or removed. Connect GitHub again.", table: "GitHubConnection", bundle: .localizedModule) }
    static var connectionError: String { String(localized: "github.connectionError", defaultValue: "GitHub reported a problem with this connection. Try again later.", table: "GitHubConnection", bundle: .localizedModule) }
    static var linkExpired: String { String(localized: "github.linkExpired", defaultValue: "The link expired; connect again.", table: "GitHubConnection", bundle: .localizedModule) }
    static func status(_ status: String?) -> String {
        if status == "active" { return String(localized: "github.connected", defaultValue: "Connected", table: "GitHubConnection", bundle: .localizedModule) }
        if status == "pending" { return pendingText }
        if status == "needs_reauth" { return reauth }
        if status == "error" { return connectionError }
        return String(localized: "github.reconnect", defaultValue: "Connect GitHub again to restore access.", table: "GitHubConnection", bundle: .localizedModule)
    }
}
