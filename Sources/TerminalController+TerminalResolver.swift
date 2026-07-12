import Darwin
import Foundation

private nonisolated struct TerminalResolverProcessIdentity: Sendable {
    let ttyDevice: Int64?
}

private nonisolated struct LiveTerminalResolverBinding: Sendable {
    let workspaceID: UUID
    let surfaceID: UUID
    let ttyName: String
    let ttyDevice: Int64?

    var payload: [String: Any] {
        [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
        ]
    }
}

extension TerminalController {
    /// Resolves one hook caller without constructing `debug.terminals` or a
    /// `system.top` process tree. Both UI topology and requested PID identity
    /// are captured fresh because ownership and PID reuse are correctness
    /// boundaries, not cacheable presentation state.
    nonisolated func v2SystemResolveTerminal(params: [String: Any]) -> V2CallResult {
        let relayWorkspaceID: UUID?
        if let rawWorkspaceID = params["_cmux_authenticated_relay_workspace_id"] {
            guard let workspaceID = rawWorkspaceID as? String,
                  let parsedWorkspaceID = UUID(uuidString: workspaceID) else {
                return .err(
                    code: "invalid_params",
                    message: "_cmux_authenticated_relay_workspace_id must be a UUID",
                    data: nil
                )
            }
            relayWorkspaceID = parsedWorkspaceID
        } else {
            relayWorkspaceID = nil
        }
        let ttyName = v2NonEmptyString(v2String(params, "tty_name")).map(Self.terminalResolverTTYName)
        let pid: Int?
        if params["pid"] != nil {
            guard let parsedPID = v2Int(params, "pid"), parsedPID > 0 else {
                return .err(code: "invalid_params", message: "pid must be a positive integer", data: nil)
            }
            pid = parsedPID
        } else {
            pid = nil
        }
        guard ttyName != nil || pid != nil else {
            return .err(code: "invalid_params", message: "tty_name or pid is required", data: nil)
        }

        let processIdentity: TerminalResolverProcessIdentity? = pid.flatMap { pid in
            Self.terminalResolverProcessIdentity(pid: pid)
        }
        let liveBindings = freshLiveTerminalResolverBindings()
        let bindings = relayWorkspaceID.map { workspaceID in
            liveBindings.filter { $0.workspaceID == workspaceID }
        } ?? liveBindings
        let ttyBindings = ttyName.map { requestedTTY in
            bindings.filter { $0.ttyName == requestedTTY }
        } ?? []
        let pidBinding = Self.pidTerminalResolverBinding(
            processIdentity,
            liveBindings: bindings
        )
        let pidBindingPayload: Any = if let pidBinding {
            pidBinding.payload
        } else {
            NSNull()
        }
        return .ok([
            "tty_bindings": ttyBindings.map(\.payload),
            "pid_binding": pidBindingPayload,
        ])
    }

    private nonisolated func freshLiveTerminalResolverBindings() -> [LiveTerminalResolverBinding] {
        let rawBindings = v2MainSync(commandKey: "system.resolve_terminal") {
            self.liveTerminalResolverBindings()
        }
        var seen: Set<String> = []
        return rawBindings.compactMap { binding -> LiveTerminalResolverBinding? in
            let key = "\(binding.workspaceID.uuidString):\(binding.surfaceID.uuidString)"
            guard seen.insert(key).inserted else { return nil }
            return LiveTerminalResolverBinding(
                workspaceID: binding.workspaceID,
                surfaceID: binding.surfaceID,
                ttyName: Self.terminalResolverTTYName(binding.ttyName),
                ttyDevice: CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: binding.ttyName)
            )
        }.sorted {
            if $0.workspaceID != $1.workspaceID {
                return $0.workspaceID.uuidString < $1.workspaceID.uuidString
            }
            return $0.surfaceID.uuidString < $1.surfaceID.uuidString
        }
    }

    private nonisolated static func terminalResolverProcessIdentity(
        pid: Int
    ) -> TerminalResolverProcessIdentity? {
        guard pid > 0,
              pid <= Int(Int32.max),
              let initialIdentity = AgentPIDProcessIdentity(pid: pid_t(pid)) else {
            return nil
        }
        var currentPID = pid
        var visited: Set<Int> = []
        var ttyDevice: Int64?
        while currentPID > 0,
              visited.insert(currentPID).inserted,
              let process = terminalResolverBSDInfo(pid: currentPID) {
            let rawTTYDevice = Int64(process.e_tdev)
            if ttyDevice == nil, rawTTYDevice > 0 {
                ttyDevice = rawTTYDevice
            }
            if ttyDevice != nil { break }
            currentPID = Int(process.pbi_ppid)
        }
        guard AgentPIDProcessIdentity(pid: pid_t(pid)) == initialIdentity else {
            return nil
        }
        return TerminalResolverProcessIdentity(ttyDevice: ttyDevice)
    }

    private nonisolated static func terminalResolverBSDInfo(pid: Int) -> proc_bsdinfo? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            pid_t(pid),
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        return size == expectedSize ? info : nil
    }

    @MainActor
    private func liveTerminalResolverBindings() -> [LiveTerminalResolverBinding] {
        guard let app = AppDelegate.shared else { return [] }
        var bindings: [LiveTerminalResolverBinding] = []
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in manager.tabs {
                for (surfaceID, rawTTY) in workspace.surfaceTTYNames
                    where workspace.panels[surfaceID] != nil {
                    bindings.append(LiveTerminalResolverBinding(
                        workspaceID: workspace.id,
                        surfaceID: surfaceID,
                        ttyName: rawTTY,
                        ttyDevice: nil
                    ))
                }
            }
        }
        return bindings
    }

    private nonisolated static func terminalResolverTTYName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private nonisolated static func pidTerminalResolverBinding(
        _ identity: TerminalResolverProcessIdentity?,
        liveBindings: [LiveTerminalResolverBinding]
    ) -> LiveTerminalResolverBinding? {
        // A CMUX scope is inherited ambient state and can survive a restored or
        // moved session. Only a unique live kernel TTY match proves ownership.
        guard let ttyDevice = identity?.ttyDevice else { return nil }
        let ttyMatches = liveBindings.filter { $0.ttyDevice == ttyDevice }
        guard ttyMatches.count == 1 else { return nil }
        return ttyMatches[0]
    }
}
