public import Foundation

/// A paired server's cmux session that the app shows next to local, SSH and
/// Cloud machines (reach `server`; plans/cmux-next/server-reach.md). The
/// session is the one a Chief placed on the server runs in (the brain's
/// headless daemon), so the workspaces it opens for subagents appear in the
/// app's sidebar under the server's name.
///
/// The record is personal routing state in the home session's registry
/// (data-model.md 1.1): the paired host and install from `team.hosts.list`
/// and `chief.list`, and how to dial the session. Never a secret.
///
/// Routes:
/// - `ssh`: the cmux-tui SSH carrier to the server, attaching to the brain's
///   existing daemon socket (`--remote-mux-socket`). Dev-only: it needs the
///   user's own SSH access to the server. Real users' paired servers need the
///   overlay route (transport.md step 5), which replaces only this route.
/// - `unix`: the server is this Mac (the user made this Mac a server); the
///   app connects to the brain's daemon socket directly.
///
/// Either way the server's daemon sees a trusted local Unix client of its
/// own user and the app reads its full tree; nothing on the server gets a
/// connection back to this Mac (no relay, `RemoteRelayPolicy.denyAll`).
public struct ServerReach: Hashable, Sendable {
    public static let transportKind = "server"
    /// The Chief brain's layout on a server (optchat-chief
    /// `deploy/brain/install.sh`: `~/.cmux/brains/chief/{bin,daemon}`).
    public static let brainBinary = "~/.cmux/brains/chief/bin/cmux-tui"
    public static let brainSocket = "~/.cmux/brains/chief/daemon/cmux.sock"
    /// The carrier session name on the server (its sidecar state), kept apart
    /// from the user's own `main` SSH session to the same machine.
    public static let brainSession = "chief"

    public enum Route: Hashable, Sendable {
        case ssh(SSHHost)
        /// An absolute socket path on this Mac.
        case unix(String)
        /// This Mac's `cmux link` socket (absolute): each connection runs the
        /// bundled `cmux` with ``dialArguments(linkSocket:)``.
        case overlay(linkSocket: String)
    }

    /// The fixed argv (after the bundled `cmux`) of an overlay connection's
    /// bridge: the server's owner session through this Mac's link, which
    /// only the server's owner may open (the server decides).
    public func dialArguments(linkSocket: String) -> [String] {
        ["link", "dial", "--host", installID, "--service", "owner_session", "--socket", linkSocket]
    }

    public struct Invalid: Error, Equatable, Sendable {
        public let field: String
    }

    /// `host_…` in the team directory.
    public let hostID: String
    /// The server's `inst_…` (the install a placed chief names).
    public let installID: String
    /// The server's display name (`Host.name`), the sidebar section title.
    public let name: String
    public let route: Route

    public init(hostID: String, installID: String, name: String, route: Route) throws(Invalid) {
        guard Self.isID(hostID, prefix: "host_") else { throw Invalid(field: "host") }
        guard Self.isID(installID, prefix: "inst_") else { throw Invalid(field: "install") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw Invalid(field: "name") }
        if case .unix(let path) = route, !Self.isLocalSocket(path) { throw Invalid(field: "socket") }
        if case .overlay(let path) = route, !Self.isLocalSocket(path) { throw Invalid(field: "link_socket") }
        self.hostID = hostID
        self.installID = installID
        self.name = trimmed
        self.route = route
    }

    /// The app's machine id for this server: stable per paired host, never
    /// `local`, an `ssh-…` or a Cloud `vm…` id.
    public var machineID: String { "server-" + hostID }

    /// The route to a placed chief's brain on a remote server over SSH:
    /// the destination is the server's host name as a DNS label (what macOS
    /// derives from a computer name: `Lawrence's Mac mini` becomes
    /// `lawrences-mac-mini`), which the user's `~/.ssh/config` and tailnet
    /// DNS resolve; nil when nothing usable is left.
    public static func brainRoute(serverName name: String) -> Route? {
        guard let host = dnsLabel(name), let destination = try? SSHDestination(parsing: host),
              let ssh = try? SSHHost(destination: destination, session: brainSession, remoteBinary: brainBinary,
                                     remoteMuxSocket: brainSocket)
        else { return nil }
        return .ssh(ssh)
    }

    /// `name` as a lowercase host name: letters, digits, dots and dashes;
    /// spaces and underscores become dashes, anything else is dropped.
    public static func dnsLabel(_ name: String) -> String? {
        var out = ""
        for scalar in name.lowercased().unicodeScalars where scalar.isASCII {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "_" {
                if !out.hasSuffix("-") { out.append("-") }
            }
        }
        let label = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return label.isEmpty ? nil : label
    }

    /// The registry `transport` object: the paired host and the route.
    public var transportFields: [String: String] {
        var fields = ["kind": Self.transportKind, "host": hostID, "install": installID, "name": name]
        switch route {
        case .ssh(let ssh):
            fields["route"] = "ssh"
            for (key, value) in ssh.transportFields where key != "kind" { fields[key] = value }
        case .unix(let path):
            fields["route"] = "unix"
            fields["socket"] = path
        case .overlay(let path):
            fields["route"] = "overlay"
            fields["link_socket"] = path
        }
        return fields
    }

    /// Reads a registry `transport` object; nil for other kinds or anything
    /// that does not validate.
    public init?(transportFields fields: [String: String]) {
        guard fields["kind"] == Self.transportKind, let host = fields["host"], let install = fields["install"],
              let name = fields["name"] else { return nil }
        let route: Route
        switch fields["route"] {
        case "ssh":
            var ssh = fields
            ssh["kind"] = SSHHost.transportKind
            guard let parsed = SSHHost(transportFields: ssh) else { return nil }
            route = .ssh(parsed)
        case "unix":
            guard let socket = fields["socket"] else { return nil }
            route = .unix(socket)
        case "overlay":
            guard let socket = fields["link_socket"] else { return nil }
            route = .overlay(linkSocket: socket)
        default:
            return nil
        }
        guard let reach = try? ServerReach(hostID: host, installID: install, name: name, route: route) else { return nil }
        self = reach
    }

    static func isID(_ text: String, prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let rest = text.dropFirst(prefix.count)
        return (8...64).contains(rest.count) && rest.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// An absolute path with plain path characters (no `..` component).
    static func isLocalSocket(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count <= 1024 && !path.split(separator: "/").contains("..")
            && path.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/._~+- ".unicodeScalars.contains($0)) }
    }
}
