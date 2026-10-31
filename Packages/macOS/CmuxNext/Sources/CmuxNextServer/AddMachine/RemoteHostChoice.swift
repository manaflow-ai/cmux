import Foundation

/// One host New Remote Group offers (remote-groups-DESIGN.md slice E): picking it makes the host a
/// remote group, connected over SSH to ``destination``.
public nonisolated struct RemoteHostChoice: Equatable, Sendable {
    /// Where the host comes from; the list shows connected hosts first, then Tailscale peers,
    /// then `~/.ssh/config` aliases.
    public enum Kind: String, Equatable, Sendable {
        /// A machine the app already has.
        case connected
        /// An online peer of this Mac's tailnet.
        case tailnet
        /// A `Host` alias of the user's OpenSSH config.
        case sshAlias
    }

    /// The SSH destination the action connects to (an alias, a MagicDNS name, `user@host`).
    public var destination: String
    /// The short name a person reads (the peer's or alias's name).
    public var name: String
    /// Where the host comes from.
    public var kind: Kind

    /// The palette row's title: the name and where the host comes from.
    public var title: String {
        let format = switch kind {
        case .connected: String(localized: "remoteGroup.host.connected", defaultValue: "%@ · Connected", table: "AddMachine", bundle: .module)
        case .tailnet: String(localized: "remoteGroup.host.tailnet", defaultValue: "%@ · Tailscale", table: "AddMachine", bundle: .module)
        case .sshAlias: String(localized: "remoteGroup.host.sshConfig", defaultValue: "%@ · SSH config", table: "AddMachine", bundle: .module)
        }
        return String(format: format, name)
    }

    /// - Parameters:
    ///   - destination: the SSH destination.
    ///   - name: the short name shown.
    ///   - kind: where the host comes from.
    public init(destination: String, name: String, kind: Kind) {
        self.destination = destination
        self.name = name
        self.kind = kind
    }

    /// The hosts to offer, each once: `connected` destinations, then online `tailnet` peers, then
    /// `sshAliases`. A host is the same one when its destination, or the first label of its name,
    /// matches case-insensitively (`mini` and `mini.tail1234.ts.net`); offline peers are left out.
    /// - Parameters:
    ///   - connected: the destinations of the app's machines.
    ///   - tailnet: Tailscale peers (`cmux-tui acp host candidates`).
    ///   - sshAliases: `~/.ssh/config` aliases (``SSHConfigHosts/aliases``).
    /// - Returns: the choices in offer order.
    public static func merge(connected: [String], tailnet: [HostCandidate], sshAliases: [String]) -> [RemoteHostChoice] {
        var choices: [RemoteHostChoice] = []
        var seen: Set<String> = []
        func add(_ choice: RemoteHostChoice) {
            let keys = [choice.destination.lowercased(), shortName(choice.destination), shortName(choice.name)]
            guard !choice.destination.isEmpty, keys.allSatisfy({ !seen.contains($0) }) else { return }
            seen.formUnion(keys)
            choices.append(choice)
        }
        for destination in connected { add(RemoteHostChoice(destination: destination, name: destination, kind: .connected)) }
        for peer in tailnet where peer.online { add(RemoteHostChoice(destination: peer.destination, name: peer.name, kind: .tailnet)) }
        for alias in sshAliases { add(RemoteHostChoice(destination: alias, name: alias, kind: .sshAlias)) }
        return choices
    }
}

/// A host's first DNS label, lowercased, without a `user@`: `me@mini.tail.ts.net` is `mini`.
private nonisolated func shortName(_ host: String) -> String {
    let bare = host.split(separator: "@").last.map(String.init) ?? host
    return (bare.split(separator: ".").first.map(String.init) ?? bare).lowercased()
}
