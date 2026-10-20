import Foundation

/// One pane whose terminal session is the runaway consumer behind critical
/// aggregate pressure, with the process groups that can be signalled to
/// release it.
struct RunawayPaneTreeTarget: Equatable, Sendable {
    let key: PaneMemoryPaneKey
    let ttyDevice: Int64
    let memoryBytes: Int64
    let processCount: Int
    let processGroupIDs: [Int]
}

/// The app's own process identity, which selection must never signal.
struct RunawayPaneTreeAppIdentity: Equatable, Sendable {
    let processID: Int
    let processGroupID: Int

    static var current: Self {
        Self(processID: Int(getpid()), processGroupID: Int(getpgrp()))
    }
}

/// Pure selection for the runaway pane-tree responder.
///
/// Terminal children are forked from cmux, so they share its resource
/// coalition and macOS attributes their memory to the app. When one pane's
/// session runs away, the kernel's low-memory path acts on that coalition and
/// takes every pane with it. Selection only names a pane when the processes
/// on its controlling tty cross the pane threshold and account for most of
/// the aggregate, so diffuse pressure never authorizes a termination.
///
/// Only processes on the pane's tty are measured or signalled: that is the
/// pane's terminal session, including workers reparented to launchd, and it
/// excludes detached apps or daemons that merely inherited the pane's
/// environment. The session root cmux spawned and, when that root is
/// `login(1)`, the shell it starts are never signalled, so the pane stays open.
/// A pane whose session root can't be found is never selected.
enum RunawayPaneTreeSelection {
    typealias TTYDeviceResolver = @Sendable (String) -> Int64?

    /// Minimum share of the aggregate bytes one pane must hold.
    static let dominanceFraction = 0.5

    static func targets(
        descriptors: [PaneMemoryDescriptor],
        snapshot: CmuxTopProcessSnapshot,
        aggregateBytes: UInt64,
        thresholdBytes: Int64,
        app: RunawayPaneTreeAppIdentity = .current,
        ttyDevice: TTYDeviceResolver = { CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: $0) }
    ) -> [RunawayPaneTreeTarget] {
        guard snapshot.captureIsAvailable,
              snapshot.enumerationIsComplete,
              aggregateBytes > 0,
              thresholdBytes > 0 else { return [] }
        let dominanceBytes = Double(aggregateBytes) * dominanceFraction
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)

        return descriptors.compactMap { descriptor in
            guard let ttyName = descriptor.ttyName,
                  let device = ttyDevice(ttyName) else { return nil }
            let pids = snapshot.pids(forTTYDevice: device)
            let memoryBytes = snapshot.summary(for: pids).memoryBytes
            guard memoryBytes >= thresholdBytes,
                  Double(memoryBytes) >= dominanceBytes,
                  let signallableGroups = signallableProcessGroupIDs(
                    ttyDevice: device,
                    in: snapshot,
                    app: app
                  ) else { return nil }
            let processGroupIDs = releasingProcessGroupIDs(
                pids: pids,
                in: snapshot,
                totalBytes: memoryBytes,
                clearBytes: clearBytes,
                allowed: signallableGroups
            )
            guard !processGroupIDs.isEmpty else { return nil }
            return RunawayPaneTreeTarget(
                key: descriptor.key,
                ttyDevice: device,
                memoryBytes: memoryBytes,
                processCount: pids.count,
                processGroupIDs: processGroupIDs
            )
        }
    }

    /// Process groups on the pane's tty that may be signalled, or nil when the
    /// session root cmux spawned is not on the tty (fail closed).
    ///
    /// Excludes the session root's group, the groups of a `login` root's
    /// direct children (the interactive shell), cmux's own group, groups 0
    /// and 1, and any group with a member that is not on this tty.
    static func signallableProcessGroupIDs(
        ttyDevice: Int64,
        in snapshot: CmuxTopProcessSnapshot,
        app: RunawayPaneTreeAppIdentity
    ) -> Set<Int>? {
        let pids = snapshot.pids(forTTYDevice: ttyDevice)
        let roots = Set(pids.filter { snapshot.process(pid: $0)?.parentPID == app.processID })
        guard !roots.isEmpty else { return nil }
        let loginRoots = Set(roots.filter { snapshot.process(pid: $0)?.name == "login" })

        var protected: Set<Int> = [0, 1, app.processGroupID]
        var candidates: Set<Int> = []
        for pid in pids {
            guard let process = snapshot.process(pid: pid),
                  let processGroupID = process.processGroupID else { continue }
            if roots.contains(pid) || loginRoots.contains(process.parentPID) {
                protected.insert(processGroupID)
            } else {
                candidates.insert(processGroupID)
            }
        }
        return candidates.subtracting(protected).filter { processGroupID in
            snapshot.pids(forProcessGroupID: processGroupID).allSatisfy {
                snapshot.process(pid: $0)?.ttyDevice == ttyDevice
            }
        }
    }

    /// Largest allowed process groups first, until the remaining session
    /// would fall below the clear level.
    static func releasingProcessGroupIDs(
        pids: Set<Int>,
        in snapshot: CmuxTopProcessSnapshot,
        totalBytes: Int64,
        clearBytes: Int64,
        allowed: Set<Int>
    ) -> [Int] {
        var bytesByProcessGroup: [Int: Int64] = [:]
        for pid in pids {
            guard let process = snapshot.process(pid: pid),
                  let processGroupID = process.processGroupID,
                  allowed.contains(processGroupID) else { continue }
            bytesByProcessGroup[processGroupID] = CmuxTopProcessSnapshot.clampedAdd(
                bytesByProcessGroup[processGroupID] ?? 0,
                max(0, process.memoryBytes)
            )
        }

        var remainingBytes = totalBytes
        var selected: [Int] = []
        for (processGroupID, memoryBytes) in bytesByProcessGroup.sorted(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }) where memoryBytes > 0 {
            guard remainingBytes >= clearBytes else { break }
            selected.append(processGroupID)
            remainingBytes -= memoryBytes
        }
        return selected.sorted()
    }
}
