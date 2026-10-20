import Foundation

/// Remote hosts (plans/cmux-next/remote-hosts.md): the sidebar's reasons for a
/// host that does not connect and the Settings status line of Remote Hosting.
/// Never names the network's vendor ("your private network").
nonisolated enum RemoteHostStrings {
    /// The header tooltip of a remote host that is not connected; `reason` is the
    /// connection's error, ending in the dial's `error_code`, or the reason `cmux host
    /// list --all` gave (`offline`, `not serving`, `no answer`, an `error_code`).
    static func dialFailure(_ reason: String) -> String {
        let code = reason.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch code {
        case "not_allowed":
            return String(localized: "remoteHost.dial.notAllowed", defaultValue: "This host does not let your account in.",
                          table: "RemoteHosting", bundle: .module)
        case "session_down":
            return String(localized: "remoteHost.dial.sessionDown", defaultValue: "cmux is not running on this host.",
                          table: "RemoteHosting", bundle: .module)
        case "offline":
            return String(localized: "remoteHost.dial.offline", defaultValue: "This host is offline or asleep.",
                          table: "RemoteHosting", bundle: .module)
        case "not serving":
            return String(localized: "remoteHost.dial.notServing", defaultValue: "Remote hosting is not on for this host.",
                          table: "RemoteHosting", bundle: .module)
        case "refused", "bad_preface", "disabled":
            return String(localized: "remoteHost.dial.refused", defaultValue: "This host refused the connection.",
                          table: "RemoteHosting", bundle: .module)
        case "unreachable", "no answer":
            return String(localized: "remoteHost.dial.unreachable", defaultValue: "Can’t reach this host on your private network.",
                          table: "RemoteHosting", bundle: .module)
        default:
            return String(format: String(localized: "remoteHost.dial.other", defaultValue: "Can’t connect: %@",
                                         table: "RemoteHosting", bundle: .module), reason)
        }
    }

    static var off: String {
        String(localized: "remoteHosting.status.off", defaultValue: "Remote hosting is off.", table: "RemoteHosting", bundle: .module)
    }

    /// Hosting runs; `name` is this Mac's name on the private network.
    static func serving(_ name: String) -> String {
        String(format: String(localized: "remoteHosting.status.serving", defaultValue: "On: your other devices can open this Mac as %@.",
                              table: "RemoteHosting", bundle: .module), name)
    }

    static var starting: String {
        String(localized: "remoteHosting.status.starting", defaultValue: "Starting remote hosting…", table: "RemoteHosting", bundle: .module)
    }

    static var notServing: String {
        String(localized: "remoteHosting.status.notServing", defaultValue: "On, but this Mac is not serving yet.", table: "RemoteHosting", bundle: .module)
    }

    /// Hosting is on, for another cmux build's session on this Mac.
    static var otherBuild: String {
        String(localized: "remoteHosting.status.otherBuild", defaultValue: "On for another cmux app on this Mac.",
               table: "RemoteHosting", bundle: .module)
    }

    /// The note of a build that may not change hosting (a tagged DEV, RC or staging build).
    static var readOnly: String {
        String(localized: "remoteHosting.status.readOnly",
               defaultValue: "Only the cmux or cmux NIGHTLY app can turn remote hosting on or off.",
               table: "RemoteHosting", bundle: .module)
    }

    static var networkOff: String {
        String(localized: "remoteHosting.status.networkOff", defaultValue: "Your private network is not connected on this Mac.",
               table: "RemoteHosting", bundle: .module)
    }

    static var changeFailed: String {
        String(localized: "remoteHosting.status.changeFailed",
               defaultValue: "Remote hosting could not be changed. Check that your private network is connected on this Mac.",
               table: "RemoteHosting", bundle: .module)
    }
}
