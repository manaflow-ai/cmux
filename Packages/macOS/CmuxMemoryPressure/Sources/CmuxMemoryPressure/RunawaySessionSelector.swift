/// One process record from the app's process census, reduced to the fields
/// runaway-session selection needs.
public struct RunawaySessionProcess: Equatable, Sendable {
    /// The process identifier.
    public let pid: Int
    /// The parent process identifier.
    public let parentPID: Int
    /// The executable name.
    public let name: String
    /// The process group, when known.
    public let processGroupID: Int?
    /// The controlling tty device, when the process has one.
    public let ttyDevice: Int64?
    /// The physical-footprint bytes.
    public let memoryBytes: Int64

    /// Creates a process record.
    public init(
        pid: Int,
        parentPID: Int,
        name: String,
        processGroupID: Int?,
        ttyDevice: Int64?,
        memoryBytes: Int64
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.processGroupID = processGroupID
        self.ttyDevice = ttyDevice
        self.memoryBytes = memoryBytes
    }
}

/// A complete process census indexed for runaway-session selection.
public struct RunawaySessionCensus: Sendable {
    let processesByPID: [Int: RunawaySessionProcess]
    let pidsByTTYDevice: [Int64: [Int]]
    let pidsByProcessGroupID: [Int: [Int]]

    /// Indexes the processes of one complete census.
    public init(processes: [RunawaySessionProcess]) {
        var processesByPID: [Int: RunawaySessionProcess] = [:]
        var pidsByTTYDevice: [Int64: [Int]] = [:]
        var pidsByProcessGroupID: [Int: [Int]] = [:]
        for process in processes where processesByPID[process.pid] == nil {
            processesByPID[process.pid] = process
            if let ttyDevice = process.ttyDevice {
                pidsByTTYDevice[ttyDevice, default: []].append(process.pid)
            }
            if let processGroupID = process.processGroupID {
                pidsByProcessGroupID[processGroupID, default: []].append(process.pid)
            }
        }
        self.processesByPID = processesByPID
        self.pidsByTTYDevice = pidsByTTYDevice
        self.pidsByProcessGroupID = pidsByProcessGroupID
    }

    func processes(onTTYDevice ttyDevice: Int64) -> [RunawaySessionProcess] {
        (pidsByTTYDevice[ttyDevice] ?? []).compactMap { processesByPID[$0] }
    }
}

/// The process groups to signal to release one runaway terminal session.
public struct RunawaySessionSelection: Equatable, Sendable {
    /// The session's controlling tty device.
    public let ttyDevice: Int64
    /// Physical-footprint bytes of every process on the tty.
    public let memoryBytes: Int64
    /// Number of processes on the tty.
    public let processCount: Int
    /// Process groups to signal, sorted ascending.
    public let processGroupIDs: [Int]
}

/// Selects the runaway job process groups of one terminal session.
///
/// Terminal children are forked from cmux, so they share its resource
/// coalition and macOS attributes their memory to the app. When one session
/// runs away, the kernel's low-memory path acts on that coalition and takes
/// every terminal with it. A session is selected only when the processes on
/// its controlling tty cross the threshold and hold most of the aggregate, so
/// diffuse pressure never selects anything.
///
/// Only processes on the session's tty are measured or signalled. That set
/// includes workers reparented to launchd and excludes detached apps that
/// merely inherited the terminal's environment. The session root the app
/// spawned and, when that root is `login(1)`, the shell it starts are never
/// signalled. A session whose root is missing is never selected.
public struct RunawaySessionSelector: Equatable, Sendable {
    /// The app's process identifier; session roots are its children.
    public let appProcessID: Int
    /// The app's process group, which is never signalled.
    public let appProcessGroupID: Int
    /// Minimum session bytes before selection.
    public let thresholdBytes: Int64
    /// Minimum share of the aggregate one session must hold.
    public let dominanceFraction: Double
    /// Fraction of the threshold the session must fall below once released.
    public let clearFraction: Double

    /// Creates a selector for one app process and threshold.
    public init(
        appProcessID: Int,
        appProcessGroupID: Int,
        thresholdBytes: Int64,
        dominanceFraction: Double = 0.5,
        clearFraction: Double = 0.8
    ) {
        self.appProcessID = appProcessID
        self.appProcessGroupID = appProcessGroupID
        self.thresholdBytes = thresholdBytes
        self.dominanceFraction = dominanceFraction
        self.clearFraction = clearFraction
    }

    /// Selects the groups to signal for the session on `ttyDevice`, or nil
    /// when the session is not the runaway consumer of `aggregateBytes`.
    public func selection(
        ttyDevice: Int64,
        in census: RunawaySessionCensus,
        aggregateBytes: UInt64
    ) -> RunawaySessionSelection? {
        guard aggregateBytes > 0, thresholdBytes > 0 else { return nil }
        let processes = census.processes(onTTYDevice: ttyDevice)
        let memoryBytes = processes.reduce(Int64(0)) { saturatingAdd($0, max(0, $1.memoryBytes)) }
        guard memoryBytes >= thresholdBytes,
              Double(memoryBytes) >= Double(aggregateBytes) * dominanceFraction,
              let allowedGroups = signallableProcessGroupIDs(ttyDevice: ttyDevice, in: census) else {
            return nil
        }

        var bytesByProcessGroup: [Int: Int64] = [:]
        for process in processes {
            guard let processGroupID = process.processGroupID,
                  allowedGroups.contains(processGroupID) else { continue }
            bytesByProcessGroup[processGroupID] = saturatingAdd(
                bytesByProcessGroup[processGroupID] ?? 0,
                max(0, process.memoryBytes)
            )
        }
        let clearBytes = Int64(Double(thresholdBytes) * clearFraction)
        var remainingBytes = memoryBytes
        var selected: [Int] = []
        for (processGroupID, groupBytes) in bytesByProcessGroup.sorted(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }) where groupBytes > 0 {
            guard remainingBytes >= clearBytes else { break }
            selected.append(processGroupID)
            remainingBytes -= groupBytes
        }
        guard !selected.isEmpty else { return nil }
        return RunawaySessionSelection(
            ttyDevice: ttyDevice,
            memoryBytes: memoryBytes,
            processCount: processes.count,
            processGroupIDs: selected.sorted()
        )
    }

    /// Process groups on the tty that may be signalled, or nil when the
    /// session root the app spawned is not on the tty.
    ///
    /// Excludes the session root's group, the groups of a `login` root's
    /// direct children (the interactive shell), the app's group, groups 0
    /// and 1, and any group with a member that is not on this tty.
    public func signallableProcessGroupIDs(
        ttyDevice: Int64,
        in census: RunawaySessionCensus
    ) -> Set<Int>? {
        let processes = census.processes(onTTYDevice: ttyDevice)
        let roots = Set(processes.filter { $0.parentPID == appProcessID }.map(\.pid))
        guard !roots.isEmpty else { return nil }
        let loginRoots = Set(processes.filter { roots.contains($0.pid) && $0.name == "login" }.map(\.pid))

        var protected: Set<Int> = [0, 1, appProcessGroupID]
        var candidates: Set<Int> = []
        for process in processes {
            guard let processGroupID = process.processGroupID else { continue }
            if roots.contains(process.pid) || loginRoots.contains(process.parentPID) {
                protected.insert(processGroupID)
            } else {
                candidates.insert(processGroupID)
            }
        }
        return candidates.subtracting(protected).filter { processGroupID in
            (census.pidsByProcessGroupID[processGroupID] ?? []).allSatisfy {
                census.processesByPID[$0]?.ttyDevice == ttyDevice
            }
        }
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}
