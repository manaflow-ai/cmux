import Darwin
import Foundation

nonisolated enum SidebarAgentFallbackActivity: Equatable, Sendable {
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

nonisolated struct SidebarAgentProcessState: Equatable, Sendable {
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
        // A newly registered PID may not have a fresh probe result yet. If the
        // cached state belongs to an older PID, treat this PID as live/running
        // until the next probe rather than letting stale death clear it.
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
        let bsdInfo = alive ? bsdInfo(for: pid) : nil
        let activeNetworkSocket = shouldInspectSocketsForNeedsInput(bsdInfo)
            ? hasActiveNetworkSocket(for: pid, expectedFDCount: Int(bsdInfo?.pbi_nfiles ?? 0))
            : false
        let activity = inferredActivity(
            isAlive: alive,
            bsdInfo: bsdInfo,
            activeNetworkSocket: activeNetworkSocket
        )
        return SidebarAgentProcessState(pid: pid, isAlive: alive, activity: activity)
    }

    static func inferredActivity(
        isAlive: Bool,
        bsdInfo: proc_bsdinfo?,
        activeNetworkSocket: Bool?
    ) -> SidebarAgentFallbackActivity {
        guard isAlive,
              let bsdInfo,
              isForegroundTerminalSleeper(bsdInfo),
              activeNetworkSocket == false else {
            return .running
        }
        return .needsInput
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

    private static func shouldInspectSocketsForNeedsInput(_ bsdInfo: proc_bsdinfo?) -> Bool {
        bsdInfo.map(isForegroundTerminalSleeper) == true
    }

    private static func isForegroundTerminalSleeper(_ info: proc_bsdinfo) -> Bool {
        Int32(info.pbi_status) == SSLEEP
            && info.e_tdev > 0
            && info.pbi_pgid > 0
            && info.e_tpgid == info.pbi_pgid
    }

    private static func hasActiveNetworkSocket(for pid: pid_t, expectedFDCount: Int) -> Bool? {
        guard expectedFDCount > 0 else { return false }
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        let maxFDProbeCapacity = 256
        let capacity = min(max(expectedFDCount + 8, 16), maxFDProbeCapacity)
        guard let bufferSize = Int32(exactly: capacity * fdInfoSize) else {
            return nil
        }
        var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let byteCount = fdInfos.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, bufferSize)
        }
        guard byteCount > 0 else { return nil }
        let returnedCount = min(Int(byteCount) / fdInfoSize, fdInfos.count)
        let filledBuffer = byteCount == bufferSize

        var sawUninspectableSocket = false
        for fdInfo in fdInfos.prefix(returnedCount) where fdInfo.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            guard let socketInfo = socketInfo(for: pid, fd: fdInfo.proc_fd) else {
                sawUninspectableSocket = true
                continue
            }
            if isActiveNetworkSocket(socketInfo) {
                return true
            }
        }
        return (sawUninspectableSocket || filledBuffer) ? nil : false
    }

    private static func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        guard let expectedSize = Int32(exactly: MemoryLayout<proc_bsdinfo>.size) else {
            return nil
        }
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        return size == expectedSize ? info : nil
    }

    private static func socketInfo(for pid: pid_t, fd: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        guard let expectedSize = Int32(exactly: MemoryLayout<socket_fdinfo>.size) else {
            return nil
        }
        let size = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, expectedSize)
        return size == expectedSize ? info : nil
    }

    private static func isActiveNetworkSocket(_ socketInfo: socket_fdinfo) -> Bool {
        let info = socketInfo.psi
        guard info.soi_family == AF_INET || info.soi_family == AF_INET6 else {
            return false
        }

        let genericState = Int32(info.soi_state)
        if genericState & Int32(SOI_S_ISCONNECTED) != 0
            || genericState & Int32(SOI_S_ISCONNECTING) != 0 {
            return true
        }

        guard info.soi_kind == SOCKINFO_TCP else {
            return false
        }
        let tcpState = info.soi_proto.pri_tcp.tcpsi_state
        return tcpState == TSI_S_ESTABLISHED
            || tcpState == TSI_S_SYN_SENT
            || tcpState == TSI_S_SYN_RECEIVED
    }
}
