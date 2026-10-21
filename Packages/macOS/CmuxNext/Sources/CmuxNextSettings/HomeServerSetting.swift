public import Foundation

/// `home.server` in cmux.json: which server Home's direct messages and group
/// chats use. `"hosted"` (the default) is cmux Cloud with the Stack sign-in;
/// `{"selfHosted": "http://mini.tail1234.ts.net:7320"}` is a self-hosted
/// `cmux-chat-server` reached over Tailscale, which knows the person by their
/// Tailscale login, so no token is sent (plans/cmux-next/dm-group-chat-DESIGN.md 4.5).
public nonisolated struct HomeServerSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "server"]
    public static let key = configPath.joined(separator: ".")
    /// The choice value of cmux Cloud.
    public static let hosted = "hosted"
    /// The member that names a self-hosted server's origin.
    public static let selfHostedKey = "selfHosted"

    /// The server the setting names.
    public nonisolated enum Value: Hashable, Sendable {
        /// cmux Cloud for this build.
        case hosted
        /// A self-hosted server, by its origin (`scheme://host[:port]`, no path).
        case selfHosted(URL)
    }

    /// The server; a value that names none is cmux Cloud plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Value, SettingsDiagnostic?) {
        _ = root
        return (.hosted, nil)
    }
}
