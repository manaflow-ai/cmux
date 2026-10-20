import Foundation

/// One pane whose process tree is the runaway consumer behind critical
/// aggregate pressure, with the process groups that can be signalled to
/// release it.
struct RunawayPaneTreeTarget: Equatable, Sendable {
    let key: PaneMemoryPaneKey
    let memoryBytes: Int64
    let processCount: Int
    let processGroupIDs: [Int]
}

/// Pure selection for the runaway pane-tree responder.
///
/// Terminal children are forked from cmux, so they share its resource
/// coalition and macOS attributes their memory to the app. When one pane's
/// tree runs away, the kernel's low-memory path acts on that coalition and
/// takes every pane with it. Selection only names a pane when its tree alone
/// crosses the pane threshold and accounts for most of the aggregate, so
/// diffuse pressure never authorizes a termination. The pane's own login and
/// shell process groups are never selected; only jobs launched from the
/// shell are.
enum RunawayPaneTreeSelection {
    /// Minimum share of the aggregate bytes one pane must hold.
    static let dominanceFraction = 0.5

    static func targets(
        descriptors: [PaneMemoryDescriptor],
        snapshot: CmuxTopProcessSnapshot,
        aggregateBytes: UInt64,
        thresholdBytes: Int64,
        currentProcessGroupID: Int = Int(getpgrp())
    ) -> [RunawayPaneTreeTarget] {
        guard snapshot.captureIsAvailable,
              snapshot.enumerationIsComplete,
              aggregateBytes > 0,
              thresholdBytes > 0 else { return [] }
        let dominanceBytes = Double(aggregateBytes) * dominanceFraction
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)

        return descriptors.compactMap { descriptor in
            let pids = panePIDs(for: descriptor, in: snapshot)
            let memoryBytes = snapshot.summary(for: pids).memoryBytes
            guard memoryBytes >= thresholdBytes,
                  Double(memoryBytes) >= dominanceBytes else { return nil }
            let protectedGroups = protectedProcessGroupIDs(pids: pids, in: snapshot)
                .union([currentProcessGroupID])
            let processGroupIDs = releasingProcessGroupIDs(
                pids: pids,
                in: snapshot,
                totalBytes: memoryBytes,
                clearBytes: clearBytes,
                excluding: protectedGroups
            )
            guard !processGroupIDs.isEmpty else { return nil }
            return RunawayPaneTreeTarget(
                key: descriptor.key,
                memoryBytes: memoryBytes,
                processCount: pids.count,
                processGroupIDs: processGroupIDs
            )
        }
    }

    /// The pane's process tree: cmux-scoped processes, the terminal
    /// foreground process, and everything on the pane's tty, with descendants.
    static func panePIDs(
        for descriptor: PaneMemoryDescriptor,
        in snapshot: CmuxTopProcessSnapshot
    ) -> Set<Int> {
        var rootPIDs = PaneMemoryGuardrail.cheapRootPIDs(for: descriptor, in: snapshot)
        rootPIDs.formUnion(snapshot.pids(forCMUXSurfaceID: descriptor.panelId))
        return snapshot.expandedPIDs(rootPIDs: rootPIDs)
    }

    /// Process groups of the tree roots and, when a root is `login(1)` (how
    /// macOS terminals start a login shell), of its direct children, which are
    /// the interactive shell. Signalling one of these would close the pane
    /// rather than stop the runaway job.
    static func protectedProcessGroupIDs(
        pids: Set<Int>,
        in snapshot: CmuxTopProcessSnapshot
    ) -> Set<Int> {
        let roots = snapshot.topLevelPIDs(for: pids)
        let loginRoots = Set(roots.filter { snapshot.process(pid: $0)?.name == "login" })
        var protected: Set<Int> = []
        for pid in pids {
            guard let process = snapshot.process(pid: pid),
                  let processGroupID = process.processGroupID else { continue }
            if roots.contains(pid) || loginRoots.contains(process.parentPID) {
                protected.insert(processGroupID)
            }
        }
        return protected
    }

    /// Largest unprotected process groups first, until the remaining tree
    /// would fall below the clear level.
    static func releasingProcessGroupIDs(
        pids: Set<Int>,
        in snapshot: CmuxTopProcessSnapshot,
        totalBytes: Int64,
        clearBytes: Int64,
        excluding protectedGroups: Set<Int>
    ) -> [Int] {
        var bytesByProcessGroup: [Int: Int64] = [:]
        for pid in pids {
            guard let process = snapshot.process(pid: pid),
                  let processGroupID = process.processGroupID,
                  processGroupID > 1,
                  !protectedGroups.contains(processGroupID) else { continue }
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
