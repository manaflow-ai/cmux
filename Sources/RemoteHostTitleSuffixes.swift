import Foundation

/// When sidebar workspaces share a title, names the remote host after each remote one's title so the
/// rows can be told apart. Gated by the `remoteTmux.originHostTitles.beta` flag at the call sites.
enum RemoteHostTitleSuffixes {
    struct Entry: Equatable {
        let id: UUID
        let title: String
        /// The remote destination (`user@host` or an ssh alias), or nil for a workspace on this Mac.
        let destination: String?
    }

    /// The host to show after each colliding remote workspace's title, keyed by workspace id.
    ///
    /// Workspaces collide when their titles match after trimming whitespace. A colliding group gets
    /// hosts only when its members come from more than one place: two hosts, or a host and this Mac.
    /// Each host drops any `user@` and the trailing domain labels every host in the group shares, but
    /// never its first label, so `main` on `web1.us-east.example.com` and on
    /// `web2.eu-west.example.com` read `web1.us-east` and `web2.eu-west`. IP addresses are never
    /// trimmed, and a lone remote host beside a local workspace keeps its whole name. The row
    /// truncates the end, so as much of the host shows as fits.
    static func suffixes(for entries: [Entry]) -> [UUID: String] {
        var groups: [String: [Entry]] = [:]
        var order: [String] = []
        for entry in entries {
            let key = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        var result: [UUID: String] = [:]
        for key in order {
            guard let group = groups[key], group.count > 1 else { continue }
            let hosts = group.map { $0.destination.flatMap(hostName) }
            // nil stands for this Mac, so a local workspace counts as its own origin.
            guard Set(hosts).count > 1 else { continue }
            let distinctHosts = Array(Set(hosts.compactMap { $0 }))
            // Trailing octets of IP addresses are not a shared domain, so an address keeps every label.
            let trims = distinctHosts.count > 1 && !distinctHosts.contains(where: isIPAddress)
            let shared = trims ? sharedTrailingLabelCount(distinctHosts) : 0
            for (entry, host) in zip(group, hosts) {
                guard let host else { continue }
                result[entry.id] = dropping(trailingLabels: shared, from: host)
            }
        }
        return result
    }

    /// The place a workspace comes from, for naming after its title. A managed Cloud VM connects
    /// through one shared gateway (`<vm id>+cmux@<gateway>`), so the VM id is what tells two VMs
    /// apart; every other remote workspace uses its destination.
    static func origin(destination: String?, cloudVMID: String?) -> String? {
        if let cloudVMID, !cloudVMID.isEmpty { return cloudVMID }
        return destination
    }

    /// Whether a host is an IPv4 or IPv6 literal rather than a name.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// The host part of a destination: everything after the last `@`, trimmed.
    static func hostName(_ destination: String) -> String? {
        var host = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        return host.isEmpty ? nil : host
    }

    /// How many trailing dot-separated labels every host shares, leaving each host at least one label.
    static func sharedTrailingLabelCount(_ hosts: [String]) -> Int {
        let labels = hosts.map { $0.split(separator: ".", omittingEmptySubsequences: false) }
        guard let first = labels.first, let shortest = labels.map(\.count).min() else { return 0 }
        var count = 0
        while count < shortest - 1 {
            let label = first[first.count - 1 - count]
            guard labels.allSatisfy({ $0[$0.count - 1 - count] == label }) else { break }
            count += 1
        }
        return count
    }

    private static func dropping(trailingLabels count: Int, from host: String) -> String {
        guard count > 0 else { return host }
        return host.split(separator: ".", omittingEmptySubsequences: false).dropLast(count).joined(separator: ".")
    }
}
