public import Foundation

/// One Cloud machine as `/api/vm` reports it. The machine id is the
/// provider VM id (`vm-…`).
public struct CloudMachine: Sendable, Hashable, Identifiable, Decodable {
    public enum Status: String, Sendable, Hashable, Decodable {
        case provisioning, running, failed, paused, destroyed, unknown
        /// A Pause Machine (or the idle auto-pause) the server accepted; the
        /// provider call has not landed yet, so the machine is not paused.
        case pausing
        /// A Resume Machine the server accepted; the VM is starting again.
        case starting
        /// A Kill Machine the server accepted; the VM is not gone yet.
        case deleting

        public init(from decoder: any Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// A machine whose daemon can be reached (or soon will be).
        public var isLive: Bool { self == .running || self == .provisioning || self == .starting }

        /// A pause, resume or delete is on its way.
        public var isChanging: Bool { self == .pausing || self == .starting || self == .deleting }

        /// Power actions wait until the current transition reaches its terminal state.
        public func blocks(_ action: PowerAction) -> Bool { isChanging }
    }

    /// Pause, Resume and Kill Machine.
    public enum PowerAction: Sendable, Hashable { case pause, resume, kill }

    /// Why the machine's last pause, resume or resize failed (the cmux-next
    /// backend's `error`): the server answers those calls at once and runs the
    /// provider call after, so a failure only shows on the record.
    public struct ChangeFailure: Sendable, Hashable, Decodable {
        public var code: String
        public var message: String
        /// When it failed; nil when the server did not say.
        public var at: Date?

        /// What to show: the message, else the code.
        public var text: String { message.isEmpty ? code : message }

        public init(code: String, message: String, at: Date? = nil) {
            self.code = code
            self.message = message
            self.at = at
        }

        private enum CodingKeys: String, CodingKey { case code, message, at }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
            at = ((try? c.decodeIfPresent(Double.self, forKey: .at)) ?? nil).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
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

    /// Diagnostics from the idle auto-pause cron. Timestamps are epoch
    /// milliseconds, matching the server's provider metadata values.
    public struct IdlePauseDiagnostics: Sendable, Hashable, Decodable {
        public struct Run: Sendable, Hashable, Decodable {
            public var checked: Int
            public var elapsedMs: Int

            public init(checked: Int, elapsedMs: Int) {
                self.checked = checked
                self.elapsedMs = elapsedMs
            }
        }

        public struct LastDecision: Sendable, Hashable, Decodable {
            public var at: Int
            public var outcome: String
            public var reason: String
            public var run: Run

            public init(at: Int, outcome: String, reason: String, run: Run) {
                self.at = at
                self.outcome = outcome
                self.reason = reason
                self.run = run
            }
        }

        public var minutes: Int
        public var lastCheckedAt: Int?
        public var idleSince: Int?
        public var lastApiActivityAt: Int?
        public var privateAddressKnown: Bool
        public var lastDecision: LastDecision?

        public init(minutes: Int, lastCheckedAt: Int?, idleSince: Int?, lastApiActivityAt: Int?,
                    privateAddressKnown: Bool, lastDecision: LastDecision?) {
            self.minutes = minutes
            self.lastCheckedAt = lastCheckedAt
            self.idleSince = idleSince
            self.lastApiActivityAt = lastApiActivityAt
            self.privateAddressKnown = privateAddressKnown
            self.lastDecision = lastDecision
        }
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
    /// Person who created the machine, when the team API supplies it.
    public var createdBy: String?
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
    /// Last idle-pause check and decision, when the server exposes diagnostics.
    public var idlePause: IdlePauseDiagnostics?
    /// What one hour of this machine's size costs, in US dollars
    /// (`hourlyRateUsd`, from the server's rate table; the app keeps none).
    /// Nil when the server has no rate for it (a size not measured yet, an
    /// older server).
    public var hourlyRateUsd: Double?
    /// The server's row revision. Status records with a newer value supersede an older
    /// local mutation; stale responses retain the optimistic overlay.
    public var updatedAt: Date?
    /// App-server row revision, kept as decimal text to avoid fixed-width overflow.
    public var serverRevision: String?
    /// When the machine last started running (`runningSince`, epoch ms).
    /// Nil while it is paused, so a paused machine shows no running cost.
    public var runningSince: Date?
    /// The auto-size pick a create with `autosize` answered (``CloudSizePick``); nil on a list
    /// record, on a create that sent its own size, and on an older server.
    public var sizePick: CloudSizePick?
    /// Why the last pause, resume or resize failed; nil when it did not (or
    /// the server does not say). The next change clears it on the server.
    public var lastChangeFailure: ChangeFailure?
    /// The newest unresolved Pause, Resume or Kill (`pausing`, `starting` or `deleting`).
    /// Never decoded: CloudMachineChanges reapplies the local overlay to incoming records.
    public var pendingChange: Status?
    /// Local mutation identity; never decoded from a server record.
    public var pendingMutationID: UUID?
    /// Local rollback settled by this record; never decoded or inferred from displayed error changes.
    public var failedMutationID: UUID?

    /// The status the app shows: a change sent from here, else the record's.
    public var shownStatus: Status { pendingChange ?? status }

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
    /// of starting (and billing) a new VM: it runs, or the idle timer paused it
    /// (opening resumes it). A changing, failed, destroyed or person-paused machine is
    /// never picked until its terminal record arrives (Lawrence msg 1334: Cloud workspaces
    /// sit in their machine's one group).
    public var takesUnnamedWorkspaces: Bool {
        !shownStatus.isChanging && (status.isLive || (status == .paused && pauseReason == .idle))
    }

    /// The machine's name wherever cmux shows one (the sidebar, menus, the Cloud page): the
    /// user's name, else the generated slug (`kind-aqua-sandpiper`); nil when it has neither.
    public var shownName: String? { displayName?.nonEmpty ?? slug?.nonEmpty }

    /// Sidebar and menu title: ``shownName``, else the id.
    public var title: String { shownName ?? id }

    enum CodingKeys: String, CodingKey {
        case id, provider, status, displayName, slug, kind, image, imageVersion, createdAt, createdBy, createdByUserId, address, size, capabilities
        case pauseReason, idlePauseMinutes, idlePause
        case hourlyRateUsd, updatedAt, runningSince, sizePick
        case lastChangeFailure = "error"
    }

    public init(id: String, provider: String = "freestyle", status: Status = .running, displayName: String? = nil,
                slug: String? = nil, address: Address? = nil, capabilities: Capabilities? = nil,
                pauseReason: PauseReason? = nil, idlePauseMinutes: Int? = nil,
                idlePause: IdlePauseDiagnostics? = nil, updatedAt: Date? = nil, lastChangeFailure: ChangeFailure? = nil) {
        self.id = id
        self.provider = provider
        self.status = status
        self.displayName = displayName
        self.createdBy = nil
        self.slug = slug
        self.address = address
        self.declaredCapabilities = capabilities
        self.pauseReason = pauseReason
        self.idlePauseMinutes = idlePauseMinutes
        self.idlePause = idlePause
        self.updatedAt = updatedAt
        self.lastChangeFailure = lastChangeFailure
    }

    /// Classic list, detail and create routes publish `{userId, displayName}`.
    /// Accept the earlier string form too, without hiding malformed machine fields.
    private struct CreatorReference: Decodable {
        let userId: String
        private enum CodingKeys: String, CodingKey { case userId }

        init(from decoder: any Decoder) throws {
            let scalar = try decoder.singleValueContainer()
            do {
                userId = try scalar.decode(String.self)
            } catch DecodingError.typeMismatch {
                let object = try decoder.container(keyedBy: CodingKeys.self)
                userId = try object.decode(String.self, forKey: .userId)
            }
        }
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
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdByUserId)
            ?? c.decodeIfPresent(CreatorReference.self, forKey: .createdBy)?.userId
        address = try c.decodeIfPresent(Address.self, forKey: .address)
        size = try c.decodeIfPresent(Size.self, forKey: .size)
        declaredCapabilities = try c.decodeIfPresent(Capabilities.self, forKey: .capabilities)
        pauseReason = (try? c.decodeIfPresent(String.self, forKey: .pauseReason)).flatMap(PauseReason.init(rawValue:))
        idlePauseMinutes = try? c.decodeIfPresent(Int.self, forKey: .idlePauseMinutes)
        // Diagnostics are best effort: older or partially deployed servers
        // may omit the object (or send a shape this client does not know).
        idlePause = try? c.decodeIfPresent(IdlePauseDiagnostics.self, forKey: .idlePause)
        updatedAt = ((try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil).map { Date(timeIntervalSince1970: $0 / 1000) }
        // Display facts: a malformed value drops the cost line, never the machine.
        hourlyRateUsd = (try? c.decodeIfPresent(Double.self, forKey: .hourlyRateUsd)) ?? nil
        runningSince = ((try? c.decodeIfPresent(Double.self, forKey: .runningSince)) ?? nil).map { Date(timeIntervalSince1970: $0 / 1000) }
        sizePick = (try? c.decodeIfPresent(CloudSizePick.self, forKey: .sizePick)) ?? nil
        lastChangeFailure = (try? c.decodeIfPresent(ChangeFailure.self, forKey: .lastChangeFailure)) ?? nil
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
    /// Only the exact `"team"`: the Cloud API says the machine is a teammate's, so its owner starts
    /// chats there. Grants nothing; it only names the refusal (``CloudMachineLink/callerIsTeammate``).
    public var callerIsTeammate: Bool { vmKind == "team" }
}

public struct CloudEnrollmentApproval: Sendable, Hashable, Decodable {
    public var approved: Bool
    public var state: String
    public var deviceFingerprint: String?
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
