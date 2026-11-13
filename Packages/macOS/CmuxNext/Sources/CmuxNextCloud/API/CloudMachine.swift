public import CmuxNextDaemon
public import Foundation

/// One Cloud machine as the app shows it: cmux-cloud-machine's record (cmux-tui
/// `crates/cmux-cloud-machine/src/record.rs`), which reads either server shape and holds every
/// rule about it. The fields are its JSON (timestamps in epoch milliseconds); the app reads them
/// and asks ``CloudMachineRules`` the rest.
public struct CloudMachine: Sendable, Hashable, Identifiable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case provisioning, running, failed, paused, destroyed, unknown
        /// A Pause Machine (or the idle auto-pause) the server accepted; not paused yet.
        case pausing
        /// A Resume Machine the server accepted; the VM is starting again.
        case starting
        /// A Kill Machine the server accepted; the VM is not gone yet.
        case deleting

        /// A machine whose daemon can be reached (or soon will be).
        public var isLive: Bool { CloudMachineRules.statuses.live.contains(self) }

        /// Paused, or a pause the server accepted: nothing should dial it until a person resumes it.
        public var isPaused: Bool { self == .paused || self == .pausing }

        /// A pause, resume or delete is on its way.
        public var isChanging: Bool { CloudMachineRules.statuses.changing.contains(self) }

        /// Power actions wait until the current transition reaches its terminal state.
        public func blocks(_ action: PowerAction) -> Bool { isChanging }
    }

    /// Pause, Resume and Kill Machine.
    public enum PowerAction: Sendable, Hashable { case pause, resume, kill }

    /// Why the machine's last pause, resume or resize failed (the record's `error`).
    public struct ChangeFailure: Sendable, Hashable, Codable {
        public var code: String
        public var message: String
        /// When it failed; nil when the server did not say.
        public var at: Date?
        /// What to show: the message, else the code.
        public var text: String

        public init(code: String, message: String, at: Date? = nil, text: String) {
            self.code = code
            self.message = message
            self.at = at
            self.text = text
        }
    }

    /// Why a paused machine is paused: the idle auto-pause or a Pause Machine.
    public enum PauseReason: String, Sendable, Hashable, Codable {
        case idle, user
    }

    /// The idle auto-pause choices, in minutes; 0 is Off. The server accepts exactly these.
    public static let idlePauseChoices = [0, 15, 30, 60, 120]

    public struct Address: Sendable, Hashable, Codable {
        public var ipv4: String?
        public var ipv6: String?
    }

    public struct Size: Sendable, Hashable, Codable {
        public var name: String?
        public var cpu: Int?
        public var memoryMb: Int?
        public var storageMb: Int?
    }

    /// Diagnostics from the idle auto-pause cron, timestamps in epoch milliseconds.
    public struct IdlePauseDiagnostics: Sendable, Hashable, Codable {
        public struct Run: Sendable, Hashable, Codable {
            public var checked: Int
            public var elapsedMs: Int

            public init(checked: Int, elapsedMs: Int) {
                self.checked = checked
                self.elapsedMs = elapsedMs
            }
        }

        public struct LastDecision: Sendable, Hashable, Codable {
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
    public struct Capabilities: Sendable, Hashable, Codable {
        /// Operations that a Cloud provider may advertise for one machine.
        public enum Operation: String, CaseIterable, Sendable, Hashable, Codable {
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
    /// Person who created the machine, when the API supplies it.
    public var createdBy: String?
    /// The team that owns the machine (the cmux-next record's `team`); nil on a classic record.
    public var team: String?
    public var address: Address?
    public var size: Size?
    /// Server-declared provider operations; nil when the record carried none.
    public var declaredCapabilities: Capabilities?
    /// Why the machine is paused; nil unless it is paused (or the server did not say).
    public var pauseReason: PauseReason?
    /// Minutes of idle before the server pauses this machine; 0 is Off.
    public var idlePauseMinutes: Int?
    public var idlePause: IdlePauseDiagnostics?
    /// What one hour of this machine's size costs, in US dollars, from the server's rate table.
    public var hourlyRateUsd: Double?
    /// The classic server's row revision.
    public var updatedAt: Date?
    /// The app server's row revision, decimal text.
    public var serverRevision: String?
    /// When the machine last started running; nil while it is paused.
    public var runningSince: Date?
    /// When the server deletes the machine if it stays paused (the record's `evict_at`); nil when
    /// the record does not say (an older server, or one not deleting paused machines yet).
    public var evictAt: Date?
    /// The auto-size pick a create with `autosize` answered.
    public var sizePick: CloudSizePick?
    /// Why the last pause, resume or resize failed; nil when it did not.
    public var lastChangeFailure: ChangeFailure?
    /// The newest unresolved Pause, Resume or Kill sent from this app (``CloudMachineChanges``).
    public var pendingChange: Status?
    /// Local mutation identity; never read from a server record.
    public var pendingMutationID: UUID?
    /// Local rollback settled by this record.
    public var failedMutationID: UUID?
    /// The cmux-next record's `desktop`: the machine serves its agent display over the link.
    public var servesDesktop = false

    /// The crate's JSON names two fields as the classic record does.
    enum CodingKeys: String, CodingKey {
        case id, provider, status, displayName, slug, kind, image, imageVersion, createdAt, createdBy, team, address, size
        case declaredCapabilities = "capabilities"
        case pauseReason, idlePauseMinutes, idlePause, hourlyRateUsd, updatedAt, serverRevision, runningSince, evictAt, sizePick
        case lastChangeFailure = "error"
        case pendingChange, pendingMutationID, failedMutationID, servesDesktop
    }

    /// The status the app shows: a change sent from here, else the record's.
    public var shownStatus: Status { pendingChange ?? status }

    /// The machine's name wherever cmux shows one: the person's name, else the generated slug.
    public var shownName: String? { displayName?.nonEmpty ?? slug?.nonEmpty }

    /// Sidebar and menu title: ``shownName``, else the id.
    public var title: String { shownName ?? id }

    /// What the app reads off this record (one FFI call; read it once per use).
    public var facts: CloudMachineRules.Facts { CloudMachineRules().facts(self) }

    /// The declared capabilities (or none), with `desktop` when the machine serves it.
    public var capabilities: Capabilities { facts.capabilities }

    /// Whether an action needing `operation` may be attempted on this machine.
    public func allows(_ operation: Capabilities.Operation) -> Bool { facts.allowed.contains(operation) }

    /// Agent infrastructure (by its shown name), not one of its owner's own machines.
    public var isAgentInfrastructure: Bool { facts.agentInfrastructure }

    public init(id: String, provider: String = "freestyle", status: Status = .running, displayName: String? = nil,
                slug: String? = nil, address: Address? = nil, capabilities: Capabilities? = nil,
                pauseReason: PauseReason? = nil, idlePauseMinutes: Int? = nil,
                idlePause: IdlePauseDiagnostics? = nil, updatedAt: Date? = nil, lastChangeFailure: ChangeFailure? = nil) {
        self.id = id
        self.provider = provider
        self.status = status
        self.displayName = displayName
        self.slug = slug
        self.address = address
        self.declaredCapabilities = capabilities
        self.pauseReason = pauseReason
        self.idlePauseMinutes = idlePauseMinutes
        self.idlePause = idlePause
        self.updatedAt = updatedAt
        self.lastChangeFailure = lastChangeFailure
    }

    /// A classic `/api/vm` record (list, detail, create, restore, fork); throws when a machine
    /// field is malformed.
    public static func classic(_ answer: Data, context: String = "machine") throws -> CloudMachine {
        try CloudMachineRules().read("machine_classic", answer, as: CloudMachine.self, context: context)
    }

    /// A record of the cmux-next backend as the Cloud app server answers it; nil without an id.
    public init?(next value: JSONValue) {
        guard let machine = try? CloudMachineRules().read("machine_next", value, as: CloudMachine.self, context: "machine") else {
            return nil
        }
        self = machine
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

public extension CloudMachine {
    /// Whether Open Desktop can show this machine: only over the carrier's `desktop` service (`cmux-rd`),
    /// so only a cmux-next machine that serves its desktop. A classic machine has no carrier route. Who may
    /// watch it is the carrier's call: it refuses anyone but the creator (`service_refused`, exit 6).
    /// The record's own `desktop` gates it, never a promoted capability (`provider_operations` may list it).
    var opensCarrierDesktop: Bool { provider == "cmux-next" && servesDesktop }
}
