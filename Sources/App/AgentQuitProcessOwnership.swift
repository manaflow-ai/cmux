import CmuxFoundation
import Darwin

/// Quit may signal this app's descendants, never a PID inferred from a writer lock.
struct AgentQuitProcessOwnership {
    let appPID: pid_t
    let snapshot: (pid_t) -> (identity: AgentPIDProcessIdentity, parentPID: pid_t)?

    init(
        appPID: pid_t = getpid(),
        snapshot: @escaping (pid_t) -> (identity: AgentPIDProcessIdentity, parentPID: pid_t)? = {
            AgentPIDProcessIdentity.processSnapshot(pid: $0)
        }
    ) {
        self.appPID = appPID
        self.snapshot = snapshot
    }

    func isOwned(_ generation: AgentPIDProcessIdentity) -> Bool {
        guard let process = snapshot(generation.pid), process.identity == generation else { return false }
        var parent = process.parentPID
        var seen: Set<pid_t> = [generation.pid]
        for _ in 0..<64 {
            if parent == appPID { return true }
            guard parent > 1, seen.insert(parent).inserted,
                  let ancestor = snapshot(parent) else { return false }
            parent = ancestor.parentPID
        }
        return false
    }
}
