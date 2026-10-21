/// One machine in an Update Everything plan: what it updates and how many of its threads run now.
public nonisolated struct UpdateEverythingMachine: Sendable, Codable, Equatable, Identifiable {
    /// Where the machine runs; it picks the update path the App uses.
    public enum Kind: String, Sendable, Codable {
        /// This Mac: the app (Sparkle) and the local agent CLIs.
        case local
        /// A machine reached over SSH: its cmux daemon is installed from this app's pinned build.
        case ssh
        /// A cmux Cloud machine: its cmux daemon is updated in place.
        case cloud
    }

    /// The machine id of `MachineRegistry` (`local` for this Mac).
    public var id: String
    /// The machine's name as the sidebar shows it.
    public var name: String
    public var kind: Kind
    /// The app's own update (Sparkle); only on the local machine.
    public var app: UpdateEverythingChange?
    /// The machine's cmux daemon, when its build differs from this app's.
    public var daemon: UpdateEverythingChange?
    /// Outdated agent CLIs the daemon can update without sudo.
    public var harnesses: [UpdateEverythingChange]
    /// Threads in a turn now; they restart on the new CLI after their turn when the person keeps
    /// "Continue threads after restarts" on.
    public var runningThreads: Int

    /// - Parameters:
    ///   - id: The machine id.
    ///   - name: The machine's name.
    ///   - kind: Where it runs.
    ///   - app: The app update, local only.
    ///   - daemon: The cmux daemon update, when its build differs.
    ///   - harnesses: The outdated agent CLIs.
    ///   - runningThreads: Threads in a turn now.
    public init(id: String, name: String, kind: Kind, app: UpdateEverythingChange? = nil, daemon: UpdateEverythingChange? = nil,
                harnesses: [UpdateEverythingChange] = [], runningThreads: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.app = app
        self.daemon = daemon
        self.harnesses = harnesses
        self.runningThreads = runningThreads
    }

    /// Every change on this machine, app first.
    public var changes: [UpdateEverythingChange] { [app, daemon].compactMap { $0 } + harnesses }

    /// Nothing to update here.
    public var isUpToDate: Bool { changes.isEmpty }

    /// Threads this machine's update restarts: only a machine whose daemon or agent CLIs change
    /// restarts any (an app update hands its agents to the new build without stopping them).
    public var interruptedThreads: Int { daemon == nil && harnesses.isEmpty ? 0 : runningThreads }
}
