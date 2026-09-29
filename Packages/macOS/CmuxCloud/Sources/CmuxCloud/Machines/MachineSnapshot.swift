import Foundation

/// One machine row's immutable render state. Rows below the lazy-list boundary
/// receive only these snapshots plus a closure bundle (snapshot-boundary rule).
public struct MachineSnapshot: Equatable, Identifiable, Sendable {
    public init(
        id: String,
        provider: String,
        image: String,
        isDesktop: Bool,
        capabilities: VMCapabilities = .all,
        activity: Activity,
        createdAt: Date? = nil,
        label: String? = nil,
        slug: String? = nil,
        freeAccess: FreeAccessState = .unrestricted,
        stats: VMStats? = nil,
        usage: MachineUsageSnapshot? = nil,
        privateAddress: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.image = image
        self.isDesktop = isDesktop
        self.capabilities = capabilities
        self.activity = activity
        self.createdAt = createdAt
        self.label = label
        self.slug = slug
        self.freeAccess = freeAccess
        self.stats = stats
        self.usage = usage
        self.privateAddress = privateAddress
        self.isPinned = isPinned
    }

    public enum Activity: Equatable, Sendable {
        /// Provisioned and reachable — wakes transparently on the next
        /// connection, so "running" and "asleep at $0" are the same green.
        case ready
        /// Still provisioning or waking.
        case pending
        /// Anything the backend reports that isn't a healthy machine.
        case attention(String)
    }

    /// Where a machine stands in the free plan's access window. The backend is
    /// the enforcement point (402 on access verbs); this mirrors it so the row
    /// can show the countdown and route a locked machine to the upgrade flow
    /// instead of a doomed connect.
    public enum FreeAccessState: Equatable, Sendable {
        /// Paid plan, or the window is disabled server-side.
        case unrestricted
        /// Reachable, with this many whole-or-partial days remaining.
        case active(daysLeft: Int)
        /// Past the window: preserved but locked until the plan is upgraded.
        case expired
    }

    public let id: String
    public let provider: String
    public let image: String
    public let isDesktop: Bool
    /// Verbs the provider can honor; menus omit Checkpoint/Fork when unsupported.
    public var capabilities: VMCapabilities = .all
    public let activity: Activity
    public let createdAt: Date?
    /// User-chosen label; nil when the machine has no label.
    public let label: String?
    /// Server-generated three-word name; nil for machines older than naming.
    public var slug: String? = nil
    /// Free-plan access window position; `.unrestricted` on paid plans.
    public var freeAccess: FreeAccessState = .unrestricted
    /// Latest activity reading; nil until the first sample lands.
    public var stats: VMStats?
    /// Coderouter spend over the usage window; nil until the team usage
    /// payload names this machine (and nil forever on backends without it).
    public var usage: MachineUsageSnapshot?
    /// The machine's address on its owner's private network; nil for machines
    /// created before private networking. v4 preferred for copy (pasteable
    /// anywhere), v6 is the fallback.
    public var privateAddress: String?
    /// True when the user explicitly pinned this machine in the Cloud tree.
    public var isPinned: Bool = false

    /// The label when set, else the generated name, else the machine id.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        if let slug, !slug.isEmpty { return slug }
        return id
    }

    /// True when the row shows something other than the id, so the id still
    /// needs a home on the second line (CLI verbs and URLs use it).
    public var showsName: Bool { displayName != id }

    public var kindLabel: String {
        isDesktop
            ? String(localized: "machines.kind.desktop", defaultValue: "Desktop")
            : String(localized: "machines.kind.base", defaultValue: "Base")
    }

    public var activityLabel: String {
        switch activity {
        case .ready:
            return String(localized: "machines.activity.ready", defaultValue: "Ready")
        case .pending:
            return String(localized: "machines.activity.pending", defaultValue: "Starting")
        case .attention(let status):
            return status
        }
    }
}
