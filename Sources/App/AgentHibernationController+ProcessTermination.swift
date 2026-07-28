import Darwin
import Foundation

extension AgentHibernationController {
    nonisolated static func processIdentities(
        for processIDs: Set<Int>
    ) -> [Int: AgentPIDProcessIdentity] {
        Dictionary(uniqueKeysWithValues: processIDs.compactMap { processID in
            guard processID > 0,
                  processID <= Int(Int32.max),
                  let identity = AgentPIDProcessIdentity(pid: pid_t(processID)) else {
                return nil
            }
            return (processID, identity)
        })
    }

    func terminateScopedProcessesForHibernation(record: AgentHibernationRecord) {
        guard !record.processIDs.isEmpty else { return }
        let currentProcessID = getpid()
        let currentProcessGroupID = getpgrp()
        var signaledProcessGroups: Set<pid_t> = []
        for rawPID in record.processIDs.sorted(by: >) {
            guard rawPID > 0, rawPID <= Int(Int32.max) else { continue }
            let pid = pid_t(rawPID)
            guard pid != currentProcessID,
                  let expectedIdentity = record.processIdentities[rawPID],
                  AgentPIDProcessIdentity(pid: pid) == expectedIdentity else {
                continue
            }
            guard let process = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: rawPID),
                  process.matchesCMUXScope(workspaceId: record.key.workspaceId, surfaceId: record.key.panelId) else {
                continue
            }
            let processGroupID = getpgid(pid)
            if processGroupID > 1,
               processGroupID != currentProcessGroupID,
               signaledProcessGroups.insert(processGroupID).inserted {
                _ = kill(-processGroupID, SIGTERM)
            }
            _ = kill(pid, SIGTERM)
        }
    }
}
