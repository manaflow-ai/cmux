import Foundation

extension CloudMachine {
    /// The name prefixes that tag a Cloud machine as agent or fleet infrastructure: VMs our agent tooling
    /// makes under a person's account (lane hosts and peers `fs-…`, probes `sr2-…`, lane VMs `lane-vm-…`,
    /// and `fleet-…` for any new kind). The Cloud API keeps no label on a machine, so the tag
    /// is the name; leo-workspace `tools/cloud-vm-up` (`FLEET_NAME_PREFIXES`) names every VM it makes
    /// with one, and the two lists stay the same.
    public static let agentInfrastructurePrefixes = ["fleet-", "fs-", "sr2-", "lane-vm-"]

    /// Whether a machine named `name` is agent infrastructure: it starts with one of
    /// ``agentInfrastructurePrefixes``, compared trimmed and case-insensitively.
    public static func isAgentInfrastructure(name: String?) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else { return false }
        return agentInfrastructurePrefixes.contains { name.hasPrefix($0) }
    }

    /// Whether this machine is agent infrastructure (by its ``shownName``), not one of its owner's own
    /// machines: the right sidebar's Machines section leaves it out (Leo, 2026-10-31: "why is there a
    /// strange right sidebar on that cloud-firstsend dev build", over fleet lane hosts and a probe
    /// listed as his machines).
    public var isAgentInfrastructure: Bool { Self.isAgentInfrastructure(name: shownName) }
}
