import Foundation

/// Remote hosts (plans/cmux-next/remote-hosts.md): the sidebar's reasons for a
/// host that does not connect and the Settings status line of Remote Hosting.
/// Never names the network's vendor ("your private network").
enum RemoteHostStrings {
    /// The header tooltip of a remote host whose dial failed; `reason` is the
    /// connection's error, ending in the dial's `error_code`.
    static func dialFailure(_ reason: String) -> String {
        let code = reason.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch code {
        case "not_allowed":
            return String(localized: "remoteHost.dial.notAllowed", defaultValue: "This host does not let your account in.",
                          table: "Server", bundle: .module)
        case "session_down":
            return String(localized: "remoteHost.dial.sessionDown", defaultValue: "cmux is not running on this host.",
                          table: "Server", bundle: .module)
        case "unreachable":
            return String(localized: "remoteHost.dial.unreachable", defaultValue: "Can’t reach this host on your private network.",
                          table: "Server", bundle: .module)
        default:
            return String(format: String(localized: "remoteHost.dial.other", defaultValue: "Can’t connect: %@",
                                         table: "Server", bundle: .module), reason)
        }
    }

    static var off: String {
        String(localized: "remoteHosting.status.off", defaultValue: "Remote hosting is off.", table: "Server", bundle: .module)
    }

    /// Hosting runs; `name` is this Mac's name on the private network.
    static func serving(_ name: String) -> String {
        String(format: String(localized: "remoteHosting.status.serving", defaultValue: "On: your other devices can open this Mac as %@.",
                              table: "Server", bundle: .module), name)
    }

    static var starting: String {
        String(localized: "remoteHosting.status.starting", defaultValue: "Starting remote hosting…", table: "Server", bundle: .module)
    }

    static var notServing: String {
        String(localized: "remoteHosting.status.notServing", defaultValue: "On, but this Mac is not serving yet.", table: "Server", bundle: .module)
    }

    static var networkOff: String {
        String(localized: "remoteHosting.status.networkOff", defaultValue: "Your private network is not connected on this Mac.",
               table: "Server", bundle: .module)
    }

    static var changeFailed: String {
        String(localized: "remoteHosting.status.changeFailed",
               defaultValue: "Remote hosting could not be changed. Check that your private network is connected on this Mac.",
               table: "Server", bundle: .module)
    }
}
