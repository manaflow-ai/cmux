public import Foundation

/// One Cloud machine as `/api/vm` reports it. The machine id is the
/// provider VM id (`vm-…`).
public struct CloudMachine: Sendable, Hashable, Identifiable, Decodable {
    public enum Status: String, Sendable, Hashable, Decodable {
        case provisioning, running, failed, paused, destroyed, unknown

        public init(from decoder: any Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// A machine whose daemon can be reached (or soon will be).
        public var isLive: Bool { self == .running || self == .provisioning }
    }

    /// Why a paused machine is paused: the idle auto-pause (`idle`) or a
    /// person or caller's Pause Machine (`user`).
    public enum PauseReason: String, Sendable, Hashable, Decodable {
        case idle, user
    }

    /// The idle auto-pause choices, in minutes; 0 is Off. The server
    /// (`web/services/vms/idlePause.ts`) accepts exactly these.
    public static let idlePauseChoices = [0, 15, 30, 60, 120]

    public struct Address: Sendable, Hashable, Decodable {
        public var ipv4: String?
        public var ipv6: String?
    }

    public struct Size: Sendable, Hashable, Decodable {
        public var name: String?
        public var cpu: Int?
        public var memoryMb: Int?
        public var storageMb: Int?
    }

    /// Provider operations and session transports advertised for this machine.
    public struct Capabilities: Sendable, Hashable, Decodable {
        /// Operations that a Cloud provider may advertise for one machine.
        public enum Operation: String, CaseIterable, Sendable, Hashable {
            case snapshot, restore, fork, exec, stats, restart, ports, desktop, sizing, persistentHome
        }

        public var snapshot: Bool
        public var restore: Bool
        public var fork: Bool
        public var exec: Bool
        public var stats: Bool
        public var restart: Bool
        public var ports: Bool
        public var desktop: Bool
        public var sizing: Bool
        public var persistentHome: Bool
        public var attachTransports: [String]

        /// Creates a conservative capability set for an older or incomplete response.
        public init(snapshot: Bool = false, restore: Bool = false, fork: Bool = false,
                    exec: Bool = false, stats: Bool = false, restart: Bool = false,
                    ports: Bool = false, desktop: Bool = false, sizing: Bool = false,
                    persistentHome: Bool = false, attachTransports: [String] = []) {
            self.snapshot = snapshot
            self.restore = restore
            self.fork = fork
            self.exec = exec
            self.stats = stats
            self.restart = restart
            self.ports = ports
            self.desktop = desktop
            self.sizing = sizing
            self.persistentHome = persistentHome
            self.attachTransports = attachTransports
        }

        /// The operations a list of capability names advertises. Accepts the
        /// contract spelling (`persistentHome`) and snake case (`persistent_home`).
        public init(names: [String]) {
            let named = Set(names.map { $0.replacingOccurrences(of: "_", with: "").lowercased() })
            func has(_ operation: Operation) -> Bool { named.contains(operation.rawValue.lowercased()) }
            self.init(snapshot: has(.snapshot), restore: has(.restore), fork: has(.fork), exec: has(.exec),
                      stats: has(.stats), restart: has(.restart), ports: has(.ports), desktop: has(.desktop),
                      sizing: has(.sizing), persistentHome: has(.persistentHome))
        }

        /// Returns whether the provider advertised an operation before the
        /// client attempts the corresponding request.
        public func supports(_ operation: Operation) -> Bool {
            switch operation {
            case .snapshot: snapshot
            case .restore: restore
            case .fork: fork
            case .exec: exec
            case .stats: stats
            case .restart: restart
            case .ports: ports
            case .desktop: desktop
            case .sizing: sizing
            case .persistentHome: persistentHome
            }
        }

        /// The advertised operations, in stable contract order.
        public var supportedOperations: [Operation] { Operation.allCases.filter(supports) }

        private enum CodingKeys: String, CodingKey {
            case snapshot, restore, fork, exec, stats, restart, ports, desktop, sizing, persistentHome, attachTransports
        }

        /// Decodes the web route's boolean object (`/api/vm`) or a list of
        /// capability names (the Cloud app server's `capabilities: [String]`).
        /// A name list advertises exactly the operations it names; names that
        /// are not provider operations (such as `agent_session`) are ignored.
        public init(from decoder: any Decoder) throws {
            if let names = try? decoder.singleValueContainer().decode([String].self) {
                self.init(names: names)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(snapshot: try c.decodeIfPresent(Bool.self, forKey: .snapshot) ?? false,
                      restore: try c.decodeIfPresent(Bool.self, forKey: .restore) ?? false,
                      fork: try c.decodeIfPresent(Bool.self, forKey: .fork) ?? false,
                      exec: try c.decodeIfPresent(Bool.self, forKey: .exec) ?? false,
                      stats: try c.decodeIfPresent(Bool.self, forKey: .stats) ?? false,
                      restart: try c.decodeIfPresent(Bool.self, forKey: .restart) ?? false,
                      ports: try c.decodeIfPresent(Bool.self, forKey: .ports) ?? false,
                      desktop: try c.decodeIfPresent(Bool.self, forKey: .desktop) ?? false,
                      sizing: try c.decodeIfPresent(Bool.self, forKey: .sizing) ?? false,
                      persistentHome: try c.decodeIfPresent(Bool.self, forKey: .persistentHome) ?? false,
                      attachTransports: try c.decodeIfPresent([String].self, forKey: .attachTransports) ?? [])
        }
    }

    public var id: String
    public var provider: String
    public var status: Status
    public var displayName: String?
    public var slug: String?
    public var kind: String?
    public var image: String?
    public var imageVersion: String?
    public var createdAt: Date?
    public var address: Address?
    public var size: Size?
    /// Server-declared provider operations and attach transports; `nil`
    /// when the record carried none (an older server, or the cmux-next
    /// backend record, whose capability names are not provider operations).
    public var declaredCapabilities: Capabilities?
    /// Why the machine is paused; `nil` unless it is paused (or the server
    /// is older and did not say).
    public var pauseReason: PauseReason?
    /// Minutes of idle before the server pauses this machine; 0 is Off.
    /// `nil` when the server did not say (an older server, or a backend
    /// machine).
    public var idlePauseMinutes: Int?
    /// What one hour of this machine's size costs, in US dollars
    /// (`hourlyRateUsd`, from the server's rate table; the app keeps none).
    /// Nil when the server has no rate for it (a size not measured yet, an
    /// older server).
    public var hourlyRateUsd: Double?
    /// When the machine last started running (`runningSince`, epoch ms).
    /// Nil while it is paused, so a paused machine shows no running cost.
    public var runningSince: Date?

    /// The declared capabilities, or the conservative empty set when the
    /// record declared none. Gate actions with ``allows(_:)``, not this.
    public var capabilities: Capabilities { declaredCapabilities ?? Capabilities() }

    /// Whether an action needing `operation` may be attempted on this
    /// machine: a declared capability set must advertise it, and a record
    /// without one keeps the behavior from before capabilities existed (the
    /// server refuses what its provider cannot do).
    public func allows(_ operation: Capabilities.Operation) -> Bool {
        declaredCapabilities?.supports(operation) ?? true
    }

    /// Whether New Cloud Workspace with no machine named may open on this machine instead
    /// of starting (and billing) a new VM: it runs or starts, or the idle timer paused it
    /// (opening resumes it). A failed machine, a destroyed one or one a person paused is
    /// never picked (Lawrence msg 1334: Cloud workspaces sit in their machine's one group).
    public var takesUnnamedWorkspaces: Bool {
        status.isLive || (status == .paused && pauseReason == .idle)
    }

    /// Sidebar and menu title: the user's name, else the slug, else the id.
    public var title: String { displayName?.nonEmpty ?? slug?.nonEmpty ?? id }

    enum CodingKeys: String, CodingKey {
        case id, provider, status, displayName, slug, kind, image, imageVersion, createdAt, address, size, capabilities
        case pauseReason, idlePauseMinutes
        case hourlyRateUsd, runningSince
    }

    public init(id: String, provider: String = "freestyle", status: Status = .running, displayName: String? = nil,
                slug: String? = nil, address: Address? = nil, capabilities: Capabilities? = nil,
                pauseReason: PauseReason? = nil, idlePauseMinutes: Int? = nil) {
        self.id = id
        self.provider = provider
        self.status = status
        self.displayName = displayName
        self.slug = slug
        self.address = address
        self.declaredCapabilities = capabilities
        self.pauseReason = pauseReason
        self.idlePauseMinutes = idlePauseMinutes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        // A create response carries no status; the machine is coming up.
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .provisioning
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        imageVersion = try c.decodeIfPresent(String.self, forKey: .imageVersion)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        address = try c.decodeIfPresent(Address.self, forKey: .address)
        size = try c.decodeIfPresent(Size.self, forKey: .size)
        declaredCapabilities = try c.decodeIfPresent(Capabilities.self, forKey: .capabilities)
        pauseReason = (try? c.decodeIfPresent(String.self, forKey: .pauseReason)).flatMap(PauseReason.init(rawValue:))
        idlePauseMinutes = try? c.decodeIfPresent(Int.self, forKey: .idlePauseMinutes)
        // Display facts: a malformed value drops the cost line, never the machine.
        hourlyRateUsd = (try? c.decodeIfPresent(Double.self, forKey: .hourlyRateUsd)) ?? nil
        runningSince = ((try? c.decodeIfPresent(Double.self, forKey: .runningSince)) ?? nil).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// `POST /api/vm/{id}/attach-endpoint {transport:"cmux-remote"}`.
public struct CloudAttachEndpoint: Sendable, Hashable, Decodable {
    public struct Invitation: Sendable, Hashable, Decodable {
        public var uri: String
        public var invitationId: String
        public var expiresAtUnix: Double
    }

    public var transport: String
    public var route: String
    public var session: String
    public var trustedCarrier: Bool
    /// Caller-relative ownership from the account API; only exact `owner` grants owner privileges.
    public var vmKind: String?
    public var expiresAtUnix: Double?
    public var invitation: Invitation?
    /// Only the exact `"owner"`: the link then starts the machine's remote chains at the VM
    /// boundary (acpmux `hub/vm_boundary.rs`). Missing, null or any other string keeps them
    /// sandboxed; a value of another type fails the attach.
    public var callerOwnsVM: Bool { vmKind == "owner" }
}

public struct CloudEnrollmentApproval: Sendable, Hashable, Decodable {
    public var approved: Bool
    public var state: String
    public var deviceFingerprint: String?
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
