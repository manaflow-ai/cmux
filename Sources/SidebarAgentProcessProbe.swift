import Darwin
import Foundation

enum SidebarAgentFallbackActivity: Equatable, Sendable {
    case running
    case needsInput

    var protocolValue: String {
        switch self {
        case .running:
            "running"
        case .needsInput:
            "needs_input"
        }
    }

    var value: String {
        switch self {
        case .running:
            String(localized: "sidebar.agentStatus.running", defaultValue: "Running")
        case .needsInput:
            String(localized: "sidebar.agentStatus.needsInput", defaultValue: "Needs input")
        }
    }

    var icon: String {
        switch self {
        case .running:
            "bolt.fill"
        case .needsInput:
            "bell.fill"
        }
    }

    var color: String {
        switch self {
        case .running, .needsInput:
            "#4C8DFF"
        }
    }
}

struct SidebarAgentProcessState: Equatable, Sendable {
    let pid: pid_t
    let isAlive: Bool
    let activity: SidebarAgentFallbackActivity
}

nonisolated enum SidebarAgentProcessProbe {
    private static let fallbackPriority = -100

    static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        errno = 0
        if kill(pid, 0) == 0 {
            return true
        }
        return POSIXErrorCode(rawValue: errno) == .EPERM
    }

    static func effectiveStatusEntry(
        key: String,
        pid: pid_t,
        explicitEntry: SidebarStatusEntry?,
        processState: SidebarAgentProcessState?
    ) -> SidebarStatusEntry? {
        let state = (processState?.pid == pid)
            ? processState
            : SidebarAgentProcessState(pid: pid, isAlive: true, activity: .running)
        guard let state, state.isAlive else { return nil }

        if let explicitEntry {
            guard explicitEntry.protocolValue.map(isRunningProtocolStatus) == true,
                  state.activity == .needsInput else {
                return explicitEntry
            }
            return entry(
                key: key,
                activity: state.activity,
                priority: explicitEntry.priority,
                timestamp: explicitEntry.timestamp,
                url: explicitEntry.url
            )
        }

        return entry(
            key: key,
            activity: state.activity,
            priority: fallbackPriority,
            timestamp: Date(timeIntervalSince1970: 0),
            url: nil
        )
    }

    /// Performs kernel process probes. Call from a utility queue and publish the
    /// returned cache value; sidebar rendering must use `effectiveStatusEntry`.
    static func processState(for pid: pid_t) -> SidebarAgentProcessState {
        let alive = isProcessAlive(pid)
        let activity: SidebarAgentFallbackActivity = alive && isLikelyBlockedOnTerminalRead(pid)
            ? .needsInput
            : .running
        return SidebarAgentProcessState(pid: pid, isAlive: alive, activity: activity)
    }

    private static func entry(
        key: String,
        activity: SidebarAgentFallbackActivity,
        priority: Int,
        timestamp: Date,
        url: URL?
    ) -> SidebarStatusEntry {
        SidebarStatusEntry(
            key: key,
            value: activity.value,
            icon: activity.icon,
            color: activity.color,
            url: url,
            priority: priority,
            format: .plain,
            timestamp: timestamp,
            protocolValue: activity.protocolValue
        )
    }

    private static func isRunningProtocolStatus(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == SidebarAgentFallbackActivity.running.protocolValue
    }

    private static func isLikelyBlockedOnTerminalRead(_ pid: pid_t) -> Bool {
        guard let info = bsdInfo(for: pid),
              Int32(info.pbi_status) == SSLEEP,
              info.e_tdev > 0,
              info.pbi_pgid > 0,
              info.e_tpgid == info.pbi_pgid else {
            return false
        }
        return true
    }

    private static func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }
}
