import Foundation

/// One process on one host. PIDs are only unique per machine, so a Cloud
/// machine's terminal processes never collide with local ones.
public struct ProcessKey: Hashable, Sendable, CustomStringConvertible {
    /// `local` for this Mac, else the machine id of a remote daemon.
    public var host: String
    public var pid: Int32

    public static let localHost = "local"

    public init(host: String = ProcessKey.localHost, pid: Int32) {
        self.host = host
        self.pid = pid
    }

    public var description: String { "\(host):\(pid)" }
}

/// Cumulative counters of one process at one instant. CPU is the total
/// user plus system time since the process started, so a percentage needs
/// two samples of the same process (``ResourceAggregator``).
public struct ProcessSample: Sendable, Equatable {
    public var key: ProcessKey
    public var name: String
    public var cpuNanos: UInt64
    /// Physical footprint on macOS (what Activity Monitor shows), resident
    /// memory on Linux.
    public var memoryBytes: UInt64
    /// Monotonic nanoseconds on the sampling host's clock. Two samples of
    /// the same process always come from the same host.
    public var sampledAtNanos: UInt64

    public init(key: ProcessKey, name: String, cpuNanos: UInt64, memoryBytes: UInt64, sampledAtNanos: UInt64) {
        self.key = key
        self.name = name
        self.cpuNanos = cpuNanos
        self.memoryBytes = memoryBytes
        self.sampledAtNanos = sampledAtNanos
    }
}

/// What a tab renders with.
public enum TabResourceKind: String, Sendable, Hashable {
    case terminal
    case chromium
    case webkit
    case other
}

/// The processes one tab owns, resolved when a sample is taken.
public struct TabResourceSources: Sendable, Equatable {
    public var tabID: String
    public var title: String
    public var kind: TabResourceKind
    /// Processes that do this tab's work: a terminal's host, shell and
    /// every descendant; a Chromium tab's renderers; a WebKit tab's
    /// WebContent process. A process may appear in several tabs (Chromium
    /// can put two tabs of one site in one renderer); totals count it once.
    public var processes: [ProcessKey]
    /// App-side memory that has no process of its own, for example a
    /// mounted Ghostty surface. An estimate; never counted twice.
    public var estimatedAppBytes: UInt64
    /// False when the owner of the numbers cannot report them (a daemon
    /// without `terminal-resources-v1`, a page that is not loaded).
    public var available: Bool

    public init(tabID: String, title: String, kind: TabResourceKind, processes: [ProcessKey],
                estimatedAppBytes: UInt64 = 0, available: Bool = true) {
        self.tabID = tabID
        self.title = title
        self.kind = kind
        self.processes = processes
        self.estimatedAppBytes = estimatedAppBytes
        self.available = available
    }
}

/// Why a process serves many tabs at once. Shared processes are reported
/// on their own line and never added to a tab.
public enum SharedRole: String, Sendable, Hashable, CaseIterable, Comparable {
    /// The cmux process itself (window chrome, Ghostty, Chromium's browser process).
    case app
    /// Chromium's GPU process.
    case gpu
    /// Chromium's network service.
    case network
    /// Other Chromium utility processes (storage, audio, ...).
    case utility
    /// Chromium extension renderers (background pages, service workers).
    case extensions

    public static func < (lhs: SharedRole, rhs: SharedRole) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct SharedProcess: Sendable, Equatable {
    public var key: ProcessKey
    public var role: SharedRole
    /// For extension renderers: the extension, when known.
    public var label: String?

    public init(key: ProcessKey, role: SharedRole, label: String? = nil) {
        self.key = key
        self.role = role
        self.label = label
    }
}

/// What a hover card or `resources` call measures.
public enum ResourceTarget: Sendable, Hashable {
    case tab(String)
    case workspace(String)
}

/// One sample: the tabs under the target, the shared processes, and the
/// counters of every process either names.
public struct ResourceSampleSet: Sendable, Equatable {
    public var tabs: [TabResourceSources]
    public var shared: [SharedProcess]
    public var samples: [ProcessKey: ProcessSample]

    public init(tabs: [TabResourceSources] = [], shared: [SharedProcess] = [], samples: [ProcessKey: ProcessSample] = [:]) {
        self.tabs = tabs
        self.shared = shared
        self.samples = samples
    }

    public static let empty = ResourceSampleSet()
}

/// CPU and memory of a set of processes.
public struct ResourceUsage: Sendable, Equatable {
    /// Share of one core over the last interval (1.0 = 100%, can exceed 1
    /// on several cores). Nil until a second sample exists.
    public var cpu: Double?
    public var memoryBytes: UInt64

    public init(cpu: Double? = nil, memoryBytes: UInt64 = 0) {
        self.cpu = cpu
        self.memoryBytes = memoryBytes
    }

    public static let zero = ResourceUsage(cpu: nil, memoryBytes: 0)
}
