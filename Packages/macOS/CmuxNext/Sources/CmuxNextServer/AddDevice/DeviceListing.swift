public import Foundation

/// The output of `cmux device list --json` (plans/cmux-next/add-device-DESIGN.md 2.4): every
/// device that can reach this computer, merged from every store, plus the network's computers
/// that are not added yet and the open invites.
public nonisolated struct DeviceListing: Equatable, Sendable, Decodable {
    /// The overlay network as this computer sees it.
    public nonisolated struct Network: Equatable, Sendable, Decodable {
        /// `tailscale`, `weft` or `none`.
        public var kind: String
        /// Signed in and running.
        public var up: Bool
        /// This computer's name on the network.
        public var this: String?
        /// Why the network is not up, as a sentence a person can act on.
        public var detail: String?

        public init(kind: String, up: Bool, this: String? = nil, detail: String? = nil) {
            self.kind = kind
            self.up = up
            self.this = this
            self.detail = detail
        }
    }

    /// One device row.
    public nonisolated struct Device: Equatable, Sendable, Decodable, Identifiable {
        /// Stable across runs (`peer:NAME`, `paired:ID`, `grant:LOGIN`, `allow:LOGIN`).
        public var id: String
        public var name: String
        /// `computer` or `phone`.
        public var kind: String
        /// `runs-agents`, `uses-this` or `watch-only`.
        public var roles: [String]
        /// `connected`, `offline`, `pending` or `error`.
        public var state: String
        public var os: String?
        /// A sentence a person can act on (an error, what a pending device waits for).
        public var detail: String?
        public var addedAt: String?
        /// A paired client machine's Full-access setting (acpmux `pair_set`); nil for every other
        /// row, which has no such setting.
        public var fullAccess: Bool?

        public init(id: String, name: String, kind: String = "computer", roles: [String], state: String,
                    os: String? = nil, detail: String? = nil, addedAt: String? = nil, fullAccess: Bool? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.roles = roles
            self.state = state
            self.os = os
            self.detail = detail
            self.addedAt = addedAt
            self.fullAccess = fullAccess
        }

        nonisolated enum CodingKeys: String, CodingKey {
            case id, name, kind, roles, state, os, detail
            case addedAt = "added_at"
            case fullAccess = "full_access"
        }
    }

    /// A computer the network knows that is not a device yet (Add Device, "On your network").
    public nonisolated struct Available: Equatable, Sendable, Decodable, Identifiable {
        public var name: String
        /// What the enroll dials: the network name, else the address.
        public var address: String
        public var os: String
        /// The same person's computer (same login, not tagged, not shared in).
        public var mine: Bool
        /// A `Host` of the person's `~/.ssh/config` (`"found": "ssh-config"`), not a network node.
        public var fromSSHConfig: Bool

        public var id: String { address }

        public init(name: String, address: String, os: String, mine: Bool, fromSSHConfig: Bool = false) {
            self.name = name
            self.address = address
            self.os = os
            self.mine = mine
            self.fromSSHConfig = fromSSHConfig
        }

        private enum CodingKeys: String, CodingKey {
            case name, address, os, mine, found
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            address = try container.decode(String.self, forKey: .address)
            os = try container.decodeIfPresent(String.self, forKey: .os) ?? ""
            mine = try container.decodeIfPresent(Bool.self, forKey: .mine) ?? false
            fromSSHConfig = try container.decodeIfPresent(String.self, forKey: .found) == "ssh-config"
        }
    }

    /// An open invite (an acpmux ticket not yet used).
    public nonisolated struct Invite: Equatable, Sendable, Decodable, Identifiable {
        public var id: String
        public var role: String
        public var label: String?

        public init(id: String, role: String, label: String? = nil) {
            self.id = id
            self.role = role
            self.label = label
        }
    }

    public var network: Network
    public var devices: [Device]
    public var available: [Available]
    public var invites: [Invite]

    public init(network: Network, devices: [Device] = [], available: [Available] = [], invites: [Invite] = []) {
        self.network = network
        self.devices = devices
        self.available = available
        self.invites = invites
    }

    /// Parses the CLI's JSON; throws when it is not a listing.
    public static func parse(_ data: Data) throws -> DeviceListing {
        try JSONDecoder().decode(DeviceListing.self, from: data)
    }
}
