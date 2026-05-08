import Darwin
import Foundation

struct SidebarAgentTitleRegistration: Equatable, Sendable {
    let statusKey: String
    let processNameNeedles: [String]
}

struct SidebarAgentPIDProbeRequest: Sendable {
    let workspaceId: UUID
    let key: String
    let pid: pid_t
}

struct SidebarAgentPIDProbeResult: Sendable {
    let workspaceId: UUID
    let key: String
    let state: SidebarAgentProcessState
}

enum SidebarAgentStatusService {
    static func titleRegistration(for title: String) -> SidebarAgentTitleRegistration? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("codex-") {
            return SidebarAgentTitleRegistration(
                statusKey: "codex",
                processNameNeedles: ["codex", "node"]
            )
        }

        return nil
    }

    static func probeResults(for requests: [SidebarAgentPIDProbeRequest]) -> [SidebarAgentPIDProbeResult] {
        requests.map { request in
            SidebarAgentPIDProbeResult(
                workspaceId: request.workspaceId,
                key: request.key,
                state: SidebarAgentProcessProbe.processState(for: request.pid)
            )
        }
    }

    static func registrationDeduplicationKey(workspaceId: UUID, statusKey: String) -> String {
        "\(workspaceId.uuidString):\(statusKey)"
    }

    static func matchedPID(
        for registration: SidebarAgentTitleRegistration,
        rootPIDs: Set<Int>,
        processSnapshot: CmuxTopProcessSnapshot
    ) -> pid_t? {
        guard !rootPIDs.isEmpty else { return nil }

        let matchedPID = processSnapshot.expandedPIDs(rootPIDs: rootPIDs)
            .compactMap { pid -> (pid: Int, info: CmuxTopProcessInfo)? in
                guard let info = processSnapshot.processInfo(for: pid) else { return nil }
                return (pid, info)
            }
            .filter { candidate in
                let haystack = ([candidate.info.name, candidate.info.path].compactMap { $0 })
                    .joined(separator: " ")
                    .lowercased()
                return registration.processNameNeedles.contains { haystack.contains($0) }
            }
            .sorted { lhs, rhs in
                let lhsParentIsRoot = rootPIDs.contains(lhs.info.parentPID)
                let rhsParentIsRoot = rootPIDs.contains(rhs.info.parentPID)
                if lhsParentIsRoot != rhsParentIsRoot {
                    return lhsParentIsRoot
                }
                if lhs.info.parentPID != rhs.info.parentPID {
                    return lhs.info.parentPID < rhs.info.parentPID
                }
                return lhs.pid < rhs.pid
            }
            .first?
            .pid

        guard let matchedPID, matchedPID > 0 else { return nil }
        return pid_t(matchedPID)
    }
}
