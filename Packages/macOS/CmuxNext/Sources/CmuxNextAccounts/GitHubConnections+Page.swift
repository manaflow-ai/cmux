public import CmuxNextSettings
import Foundation

extension GitHubConnections {
    public var pageState: JSONValue {
        let note: String
        if scopeIsSignedOut { note = Self.signIn }
        else if error { note = Self.failed }
        else if pending { note = Self.pendingText }
        else if connected { note = Self.status("active") }
        else if !ready, !busy { note = Self.unavailable }
        else { note = Self.detail }
        return [
            "outcome": .string(scopeIsSignedOut ? "needs-action" : error ? "failed" : (pending || busy) ? "pending" : connected ? "connected" : "needs-action"),
            "title": "GitHub", "detail": .string(note), "busy": .bool(busy),
            "connect": .string(Self.connect), "disconnect": .string(Self.disconnect),
            "confirm": .string(Self.confirm), "cancel": .string(Self.cancel),
            "refresh": .string(Self.refresh), "canConnect": .bool(canConnect),
            "connections": .array(currentConnections.map { row in
                ["id": row["id"] ?? .null,
                 "account": row["account"]?["name"] ?? "GitHub",
                 "status": .string(Self.status(row["status"]?.stringValue)),
                 "canDisconnect": .bool(canDisconnect(row)),
                 "permissions": row["scopes_granted"] ?? .array([])]
            }),
        ]
    }
}

private extension GitHubConnections {
    static var connect: String { String(localized: "github.connect", defaultValue: "Connect GitHub", table: "GitHubConnection", bundle: .module) }
    static var disconnect: String { String(localized: "github.disconnect", defaultValue: "Disconnect", table: "GitHubConnection", bundle: .module) }
    static var confirm: String { String(localized: "github.confirm", defaultValue: "Disconnect GitHub? Agents will lose access through this connection.", table: "GitHubConnection", bundle: .module) }
    static var cancel: String { String(localized: "github.cancel", defaultValue: "Cancel", table: "GitHubConnection", bundle: .module) }
    static var refresh: String { String(localized: "github.refresh", defaultValue: "Refresh", table: "GitHubConnection", bundle: .module) }
    static var detail: String { String(localized: "github.detail", defaultValue: "Connect the cmux GitHub App. Choose repositories and review permissions in GitHub.", table: "GitHubConnection", bundle: .module) }
    static var signIn: String { String(localized: "github.signIn", defaultValue: "Sign in to cmux to connect GitHub.", table: "GitHubConnection", bundle: .module) }
    static var unavailable: String { String(localized: "github.unavailable", defaultValue: "GitHub connections are unavailable on this deployment.", table: "GitHubConnection", bundle: .module) }
    static var pendingText: String { String(localized: "github.pending", defaultValue: "Finish connecting in your browser, then refresh.", table: "GitHubConnection", bundle: .module) }
    static var failed: String { String(localized: "github.failed", defaultValue: "GitHub could not be updated. Refresh to try again.", table: "GitHubConnection", bundle: .module) }
    static func status(_ status: String?) -> String {
        if status == "active" { return String(localized: "github.connected", defaultValue: "Connected", table: "GitHubConnection", bundle: .module) }
        if status == "pending" { return pendingText }
        return String(localized: "github.reconnect", defaultValue: "Connect GitHub again to restore access.", table: "GitHubConnection", bundle: .module)
    }
}
