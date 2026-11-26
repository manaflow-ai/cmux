import Foundation

/// Why a process that shares a surface's TTY device was, or was not, attributed to it.
///
/// A terminal's TTY is not proof of ownership. A process reparented to launchd keeps the
/// controlling TTY of the terminal it was launched from, so the TTY population always has
/// to be split into processes cmux can prove it owns and processes that merely collide on
/// the device. See https://github.com/manaflow-ai/cmux/issues/11004.
enum CmuxTopTTYOwnershipReason: String, Sendable, CaseIterable {
    /// The process carries an explicit `CMUX_*` scope naming this surface. Strongest
    /// evidence, and the one that survives reparenting: hook monitors and browser roots
    /// are intentionally launchd-parented but stay attributed through it.
    case cmuxProcessScope = "cmux-process-scope"

    /// The process was already proven through the surface's cmux-scoped process tree.
    case surfaceProcessTree = "surface-process-tree"

    /// The process was launched onto this TTY by a cmux-owned process off the TTY, which
    /// is how the shell cmux forks for a surface looks.
    case ttySessionRoot = "tty-session-root"

    /// The process descends from a proven owner on this TTY.
    case ttyDescendant = "tty-descendant"

    /// The process belongs to a process group whose leader is a proven owner, which is how
    /// a backgrounded job of the surface's shell looks after its parent goes away.
    case ttyProcessGroup = "tty-process-group"

    /// The process only shares the TTY device. No descendant, process-group, or cmux-scope
    /// evidence links it to the surface, so its memory is not cmux's to claim.
    case ttyCollision = "tty-collision"
}

/// The minimum a process has to expose for TTY ownership to be decidable.
struct CmuxTopTTYOwnershipProcess: Sendable, Equatable {
    /// The process identifier.
    let pid: Int
    /// The parent process identifier. `1` means launchd, i.e. the process was reparented
    /// and its parent link no longer says who started it.
    let parentPID: Int
    /// The process group identifier, when the snapshot could read one.
    let processGroupID: Int?
    /// The cmux surface named by the process's `CMUX_*` environment scope, when present.
    let cmuxSurfaceID: UUID?

    /// Creates the process facts used to decide TTY ownership.
    init(pid: Int, parentPID: Int, processGroupID: Int?, cmuxSurfaceID: UUID?) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.cmuxSurfaceID = cmuxSurfaceID
    }
}

/// The result of splitting one TTY's process population by ownership evidence.
struct CmuxTopTTYOwnership: Sendable {
    /// Processes cmux can prove belong to the surface. Safe to use as attribution roots.
    var provenPIDs: Set<Int> = []

    /// Processes that share the TTY device with no ownership evidence. Reported separately
    /// so a detached REPL or dev server is visible without being charged to the surface.
    var unattributedPIDs: Set<Int> = []

    /// Per-PID reason, for diagnostics and the Task Manager.
    var reasonByPID: [Int: CmuxTopTTYOwnershipReason] = [:]

    /// String-keyed reasons for the JSON payloads, which cannot carry `Int` keys.
    func reasonPayload() -> [String: String] {
        var payload: [String: String] = [:]
        payload.reserveCapacity(reasonByPID.count)
        for (pid, reason) in reasonByPID {
            payload[String(pid)] = reason.rawValue
        }
        return payload
    }
}

/// Decides which processes on a surface's TTY the surface actually owns.
///
/// Attribution fails closed: a PID is charged to the surface only when the snapshot
/// carries positive evidence for it, so an unrelated detached workload that merely
/// inherited the TTY is reported rather than summed into cmux's memory.
struct CmuxTopTTYOwnershipResolver {
    /// PIDs known to belong to cmux — the window's app processes and their descendants.
    /// A process launched onto the TTY by one of these is a surface root; without this
    /// evidence an off-TTY parent proves nothing.
    private let cmuxOwnedPIDs: Set<Int>

    /// Creates a resolver that trusts `cmuxOwnedPIDs` as launch evidence.
    init(cmuxOwnedPIDs: Set<Int>) {
        self.cmuxOwnedPIDs = cmuxOwnedPIDs
    }

    /// Splits `candidates` into proven owners of `surfaceID` and same-TTY collisions.
    ///
    /// Runs in time linear in the candidate count: parent and process-group indexes are
    /// built once, then each newly proven PID is visited exactly once from a work queue.
    ///
    /// - Parameters:
    ///   - candidates: every PID sharing the surface's TTY device.
    ///   - processes: process facts for those PIDs. A PID missing here cannot be proven.
    ///   - surfaceID: the surface being annotated, when it has an identifier.
    ///   - provenPIDs: PIDs already proven by a stronger path, such as the expanded
    ///     cmux-scoped process tree for this surface.
    /// - Returns: the proven set, the unattributed set, and the reason for each PID.
    func resolve(
        candidates: Set<Int>,
        processes: [Int: CmuxTopTTYOwnershipProcess],
        surfaceID: UUID?,
        provenPIDs: Set<Int> = []
    ) -> CmuxTopTTYOwnership {
        var ownership = CmuxTopTTYOwnership()
        let livePIDs = candidates.filter { $0 > 0 }
        guard !livePIDs.isEmpty else { return ownership }

        // Built once so propagation never rescans the candidate set.
        var childrenByParentPID: [Int: [Int]] = [:]
        var membersByProcessGroupID: [Int: [Int]] = [:]
        for pid in livePIDs {
            guard let process = processes[pid] else { continue }
            if process.parentPID > 1 {
                childrenByParentPID[process.parentPID, default: []].append(pid)
            }
            if let processGroupID = process.processGroupID, processGroupID != pid {
                membersByProcessGroupID[processGroupID, default: []].append(pid)
            }
        }

        var proven: Set<Int> = []
        var queue: [Int] = []

        func prove(_ pid: Int, _ reason: CmuxTopTTYOwnershipReason) {
            guard proven.insert(pid).inserted else { return }
            ownership.reasonByPID[pid] = reason
            queue.append(pid)
        }

        for pid in livePIDs {
            guard let process = processes[pid] else { continue }

            if let surfaceID, process.cmuxSurfaceID == surfaceID {
                prove(pid, .cmuxProcessScope)
                continue
            }
            if provenPIDs.contains(pid) {
                prove(pid, .surfaceProcessTree)
                continue
            }
            // An off-TTY parent only proves ownership when that parent is cmux's. PID 1 is
            // launchd, and an arbitrary third-party parent says nothing about this surface.
            if process.parentPID > 1,
               !livePIDs.contains(process.parentPID),
               cmuxOwnedPIDs.contains(process.parentPID) {
                prove(pid, .ttySessionRoot)
            }
        }

        // Ownership is transitive: a child of a proven owner is proven, and so is a member
        // of a process group whose leader is proven. Each proven PID is expanded once.
        while let pid = queue.popLast() {
            for child in childrenByParentPID[pid] ?? [] {
                prove(child, .ttyDescendant)
            }
            for member in membersByProcessGroupID[pid] ?? [] {
                prove(member, .ttyProcessGroup)
            }
        }

        ownership.provenPIDs = proven
        for pid in livePIDs where !proven.contains(pid) {
            ownership.unattributedPIDs.insert(pid)
            ownership.reasonByPID[pid] = .ttyCollision
        }
        return ownership
    }
}
