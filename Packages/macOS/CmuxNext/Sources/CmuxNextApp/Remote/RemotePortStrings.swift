import Foundation

/// Text of the SSH machine port actions and Switch Host…. Keys live in Resources/Remote.xcstrings.
extension RemoteStrings {
    static func portForwarded(_ port: Int, _ machine: String, _ address: String) -> String { String(format: String(localized: "remote.port.forwarded", defaultValue: "Forwarded port %1$d of %2$@ to %3$@", table: "Remote", bundle: .module.inAppLanguage), port, machine, address) }
    static func noForwardedPorts(_ machine: String) -> String { String(format: String(localized: "remote.port.none", defaultValue: "No ports are forwarded from %@.", table: "Remote", bundle: .module.inAppLanguage), machine) }
    static func portNotForwarded(_ port: Int, _ machine: String) -> String { String(format: String(localized: "remote.port.notForwarded", defaultValue: "Port %1$d of %2$@ is not forwarded.", table: "Remote", bundle: .module.inAppLanguage), port, machine) }
    static func portClosed(_ port: Int, _ machine: String) -> String { String(format: String(localized: "remote.port.closed", defaultValue: "Stopped forwarding port %1$d of %2$@.", table: "Remote", bundle: .module.inAppLanguage), port, machine) }
    static var needsPort: String { String(localized: "remote.port.needsPort", defaultValue: "Pass --port N, a port from 1 to 65535.", table: "Remote", bundle: .module.inAppLanguage) }
    static func linkDidNotAnswer(_ machine: String) -> String { String(format: String(localized: "remote.port.noAnswer", defaultValue: "The link to %@ did not answer.", table: "Remote", bundle: .module.inAppLanguage), machine) }
    static var noHostChosen: String { String(localized: "remote.switch.noHost", defaultValue: "No host is chosen. Pass --target machine:<id>.", table: "Remote", bundle: .module.inAppLanguage) }
}
