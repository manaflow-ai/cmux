/// What one terminal session is using, for telling the user which terminal
/// is running away.
public struct RunawaySessionUsage: Equatable, Sendable {
    /// The session's controlling tty device.
    public let ttyDevice: Int64
    /// Physical-footprint bytes of every process on the tty.
    public let memoryBytes: Int64
    /// Number of processes on the tty.
    public let processCount: Int
    /// The process that best names the runaway: the leader of the job group
    /// holding the most memory, or its largest member when the leader is gone.
    public let dominantProcessID: Int?

    /// Creates a usage value.
    public init(ttyDevice: Int64, memoryBytes: Int64, processCount: Int, dominantProcessID: Int?) {
        self.ttyDevice = ttyDevice
        self.memoryBytes = memoryBytes
        self.processCount = processCount
        self.dominantProcessID = dominantProcessID
    }
}

extension RunawaySessionCensus {
    /// The usage of the session on `ttyDevice`, or nil when nothing is on it.
    ///
    /// The dominant process is chosen among `candidateGroups` (the groups that
    /// may be signalled) when any hold memory, so the label names the job
    /// rather than the shell.
    public func usage(
        ttyDevice: Int64,
        candidateGroups: Set<Int> = []
    ) -> RunawaySessionUsage? {
        let processes = processes(onTTYDevice: ttyDevice)
        guard !processes.isEmpty else { return nil }
        var memoryBytes: Int64 = 0
        var bytesByGroup: [Int: Int64] = [:]
        for process in processes {
            let bytes = max(0, process.memoryBytes)
            memoryBytes = Self.saturatingAdd(memoryBytes, bytes)
            if let group = process.processGroupID {
                bytesByGroup[group] = Self.saturatingAdd(bytesByGroup[group] ?? 0, bytes)
            }
        }
        let preferred = bytesByGroup.filter { candidateGroups.contains($0.key) && $0.value > 0 }
        let ranked = (preferred.isEmpty ? bytesByGroup : preferred).sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }
        var dominantProcessID: Int?
        if let group = ranked.first?.key {
            if processesByPID[group]?.processGroupID == group,
               processesByPID[group]?.ttyDevice == ttyDevice {
                dominantProcessID = group
            } else {
                dominantProcessID = processes
                    .filter { $0.processGroupID == group }
                    .max { ($0.memoryBytes, -$0.pid) < ($1.memoryBytes, -$1.pid) }?
                    .pid
            }
        }
        return RunawaySessionUsage(
            ttyDevice: ttyDevice,
            memoryBytes: memoryBytes,
            processCount: processes.count,
            dominantProcessID: dominantProcessID
        )
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

/// When a terminal session counts as running away, for the user warning.
public struct RunawaySessionWarningPolicy: Equatable, Sendable {
    /// Session memory at or above which the user is warned.
    public let memoryThresholdBytes: Int64
    /// Session process count at or above which the user is warned.
    public let processCountThreshold: Int
    /// Fraction of both thresholds a warned session must fall below to clear.
    public let clearFraction: Double

    /// Creates a policy.
    public init(
        memoryThresholdBytes: Int64,
        processCountThreshold: Int = 1_000,
        clearFraction: Double = 0.8
    ) {
        self.memoryThresholdBytes = max(1, memoryThresholdBytes)
        self.processCountThreshold = max(1, processCountThreshold)
        self.clearFraction = min(max(clearFraction, 0), 1)
    }

    /// Whether the session crossed either threshold.
    public func isRunaway(_ usage: RunawaySessionUsage) -> Bool {
        usage.memoryBytes >= memoryThresholdBytes || usage.processCount >= processCountThreshold
    }

    /// Whether a warned session fell below the clear level on both measures.
    public func hasCleared(_ usage: RunawaySessionUsage) -> Bool {
        Double(usage.memoryBytes) < Double(memoryThresholdBytes) * clearFraction &&
            Double(usage.processCount) < Double(processCountThreshold) * clearFraction
    }
}

/// Edge-triggered warning state per terminal: a session warns once when it
/// crosses the policy, stays warned through the hysteresis band, and can warn
/// again after it clears. A dismissed warning stays quiet until it clears.
public struct RunawaySessionWarningTracker<Key: Hashable & Sendable>: Sendable {
    /// Terminals currently over the policy.
    private(set) var warned: Set<Key> = []
    /// Warned terminals whose warning the user dismissed.
    private(set) var dismissed: Set<Key> = []

    /// Creates an empty tracker.
    public init() {}

    /// Ingests the current usage of every live terminal and returns the
    /// terminals that newly need a warning. Live terminals whose measurement
    /// is unavailable retain their warning and dismissal state; closed ones
    /// are forgotten.
    public mutating func ingest(
        _ usages: [Key: RunawaySessionUsage],
        unavailableKeys: Set<Key> = [],
        policy: RunawaySessionWarningPolicy
    ) -> Set<Key> {
        let live = Set(usages.keys).union(unavailableKeys)
        warned.formIntersection(live)
        dismissed.formIntersection(live)
        var newlyWarned: Set<Key> = []
        for (key, usage) in usages {
            if policy.isRunaway(usage) {
                if warned.insert(key).inserted { newlyWarned.insert(key) }
            } else if policy.hasCleared(usage) {
                warned.remove(key)
                dismissed.remove(key)
            }
        }
        return newlyWarned
    }

    /// Whether `key` has a warning the user should still see.
    public func isPresentable(_ key: Key) -> Bool {
        warned.contains(key) && !dismissed.contains(key)
    }

    /// Hides the warning for `key` until its session clears.
    public mutating func dismiss(_ key: Key) {
        guard warned.contains(key) else { return }
        dismissed.insert(key)
    }

    /// Forgets `key`, so a new runaway in the same terminal warns again.
    public mutating func reset(_ key: Key) {
        warned.remove(key)
        dismissed.remove(key)
    }
}

/// Names a process without exposing arbitrary argv in desktop notifications.
public struct RunawaySessionCommandLabeler: Sendable {
    /// Interpreters whose script argument names the command better.
    public let interpreters: Set<String>
    /// Maximum label length in characters.
    public let maximumLength: Int

    /// Creates a labeler.
    public init(
        interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl", "java"],
        maximumLength: Int = 60
    ) {
        self.interpreters = interpreters
        self.maximumLength = max(8, maximumLength)
    }

    /// Uses the process name, or an allowlisted tool and subcommand such as
    /// `next dev`. Paths, option values, code and other arguments stay private.
    public func label(arguments: [String], processName: String) -> String {
        let name = basename(processName)
        var label = name
        let commands: [String: Set<String>] = [
            "next": ["dev", "build", "start"],
            "vite": ["dev", "build", "preview"],
            "webpack": ["serve", "watch"],
        ]
        // Only argv[1] may name a script. Looking past arbitrary flags could
        // mistake a credential or inline program for a script name.
        if isInterpreter(name), arguments.count > 1 {
            let script = basename(arguments[1])
            if let subcommands = commands[script] {
                label = script
                if arguments.count > 2, subcommands.contains(arguments[2]) {
                    label += " " + arguments[2]
                }
            }
        }
        guard label.count > maximumLength else { return label }
        return String(label.prefix(maximumLength - 1)) + "…"
    }

    /// Versioned names such as `python3.12` count as their interpreter.
    private func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || interpreters.contains {
            name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." }
        }
    }

    private func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = path[path.index(after: slash)...]
        return name.isEmpty ? path : String(name)
    }
}
