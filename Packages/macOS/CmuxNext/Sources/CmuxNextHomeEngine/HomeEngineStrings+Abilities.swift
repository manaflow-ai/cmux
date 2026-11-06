import Foundation

/// The Chief Settings card's Computer note, Vault and Connections sections (cmux issue 34263).
extension HomeEngineStrings {
    static var computerNote: String {
        String(localized: "home.engine.computer.note", defaultValue: "Chief’s own computer for computer-use tasks.", table: "Home", bundle: .module)
    }
    static var vaultSection: String { String(localized: "home.engine.vault", defaultValue: "Vault", table: "Home", bundle: .module) }
    static var vaultEmpty: String {
        String(localized: "home.engine.vault.empty", defaultValue: "No credentials yet", table: "Home", bundle: .module)
    }
    static var vaultUnreadable: String {
        String(localized: "home.engine.vault.unreadable", defaultValue: "The vault couldn’t be read", table: "Home", bundle: .module)
    }
    /// "3 credentials: A, B, C" (the names only, never a value).
    static func vaultNames(_ count: Int, _ names: String) -> String {
        String(localized: "home.engine.vault.names", defaultValue: "\(count) saved: \(names)", table: "Home", bundle: .module)
    }
    static var vaultNote: String {
        String(localized: "home.engine.vault.note",
               defaultValue: "Kept in your Keychain. Chief and its agents use them by name; values never appear in chat. Add one with cmux cloud secret set NAME.",
               table: "Home", bundle: .module)
    }
    static var connectionsSection: String {
        String(localized: "home.engine.connections", defaultValue: "Connections", table: "Home", bundle: .module)
    }
    static var connectionsNote: String {
        String(localized: "home.engine.connections.note",
               defaultValue: "Chief reads and sends only through a connected account. It asks you before it sends an email or an invitation.",
               table: "Home", bundle: .module)
    }
    static var connectionGmail: String { String(localized: "home.engine.connection.gmail", defaultValue: "Gmail", table: "Home", bundle: .module) }
    static var connectionCalendar: String {
        String(localized: "home.engine.connection.calendar", defaultValue: "Google Calendar", table: "Home", bundle: .module)
    }
    static var connectionConnect: String { String(localized: "home.engine.connection.connect", defaultValue: "Connect", table: "Home", bundle: .module) }
    static var connectionDisconnect: String {
        String(localized: "home.engine.connection.disconnect", defaultValue: "Disconnect", table: "Home", bundle: .module)
    }
    static var connectionReconnect: String {
        String(localized: "home.engine.connection.reconnect", defaultValue: "Connect Again", table: "Home", bundle: .module)
    }
    static var connectionPending: String {
        String(localized: "home.engine.connection.pending", defaultValue: "Finish in your browser", table: "Home", bundle: .module)
    }
    static var connectionSignedOut: String {
        String(localized: "home.engine.connection.signedOut", defaultValue: "Sign in to cmux", table: "Home", bundle: .module)
    }
    static var connectionUnavailable: String {
        String(localized: "home.engine.connection.unavailable", defaultValue: "Not available", table: "Home", bundle: .module)
    }
    static var connectionNotConnected: String {
        String(localized: "home.engine.connection.notConnected", defaultValue: "Not connected", table: "Home", bundle: .module)
    }
    static var connectionNeedsReauth: String {
        String(localized: "home.engine.connection.needsReauth", defaultValue: "Access ended", table: "Home", bundle: .module)
    }
    static var connectionFailed: String {
        String(localized: "home.engine.connection.failed", defaultValue: "Connections couldn’t be updated. Open the card again to retry.", table: "Home", bundle: .module)
    }
}
