import Foundation

/// Remote localhost chip text. Keys live in Resources/RemoteLocalhost.xcstrings.
enum RemoteLocalhostStrings {
    /// The chip when localhost stays this Mac for a remote tab.
    static var thisMac: String {
        String(localized: "remoteLocalhost.badge.thisMac", defaultValue: "this Mac", table: "RemoteLocalhost", bundle: .module)
    }

    static func helpMachine(_ machine: String) -> String {
        String(localized: "remoteLocalhost.help.machine", defaultValue: "localhost is \(machine)", table: "RemoteLocalhost", bundle: .module)
    }

    static func helpUpdate(_ machine: String) -> String {
        String(localized: "remoteLocalhost.help.update",
               defaultValue: "localhost is this Mac. Update \(machine) to use its localhost here.", table: "RemoteLocalhost", bundle: .module)
    }

    static var helpTurnedOff: String {
        String(localized: "remoteLocalhost.help.turnedOff",
               defaultValue: "localhost is this Mac: browser.remoteLocalhost is off for this workspace.", table: "RemoteLocalhost", bundle: .module)
    }

    static func helpWebKit(_ machine: String) -> String {
        String(localized: "remoteLocalhost.help.webKit",
               defaultValue: "localhost is this Mac: WebKit tabs cannot use \(machine)’s localhost yet. Open it in Chromium.",
               table: "RemoteLocalhost", bundle: .module)
    }
}
