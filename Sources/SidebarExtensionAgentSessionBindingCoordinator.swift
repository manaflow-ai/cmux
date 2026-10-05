import CMUXAgentLaunch
@_spi(CmuxHostTransport) import CmuxExtensionKit
import Darwin
import Foundation

/// Applies an explicit user SID to exactly one native process that still owns the selected surface.
@MainActor
struct SidebarExtensionAgentSessionBindingCoordinator {
    let tabManager: TabManager
    var processIdentity: (pid_t) -> AgentPIDProcessIdentity? = { AgentPIDProcessIdentity(pid: $0) }
    var ownsSurface: (pid_t, UUID, UUID) -> Bool = { pid, workspaceID, surfaceID in
        guard let target = AppDelegate.shared?.liveAgentDeliveryTarget(forAgentPID: pid, resolution: .controllingTTY) else { return false }
        return target.workspaceId == workspaceID && target.surfaceId == surfaceID
    }
    var now: () -> Date = { Date() }

    func perform(_ action: CmuxSidebarAction) -> CmuxSidebarActionResult? {
        guard case .bindAgentSession(let workspaceID, let surfaceID, let toolID, let sessionID, let generation) = action else { return nil }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              workspace.terminalPanel(for: surfaceID) != nil,
              sessionID == sessionID.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty, sessionID.count <= 256,
              sessionID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0) }),
              let kind = resumeKind(toolID),
              let argv = resumeArguments(kind: kind, sessionID: sessionID) else { return unavailable }
        let model = workspace.sidebarAgentRuntimeObservation
        let candidates = Set((model.agentPIDKeysByPanelId[surfaceID] ?? []).compactMap { key -> AgentPIDProcessIdentity? in
            guard workspace.agentStatusKey(forAgentPIDKey: key) == toolID,
                  model.agentPIDPanelIdsByKey[key] == surfaceID,
                  let pid = model.agentPIDs[key], let identity = model.agentPIDProcessIdentitiesByKey[key],
                  identity.pid == pid, processIdentity(pid) == identity else { return nil }
            return identity
        })
        guard candidates.count == 1, let identity = candidates.first,
              birthGeneration(identity) == generation,
              ownsSurface(identity.pid, workspaceID, surfaceID) else { return unavailable }
        let binding = SurfaceResumeBindingSnapshot(name: kind, kind: kind,
            command: renderedCommand(kind: kind, arguments: argv),
            cwd: workspace.currentDirectory, checkpointId: sessionID, source: "user-sidebar",
            autoResume: false, updatedAt: now().timeIntervalSince1970)
        guard workspace.setSurfaceResumeBinding(binding, panelId: surfaceID) else { return unavailable }
        let key = toolID + "." + sessionID
        _ = workspace.recordAgentPID(key: key, pid: identity.pid, panelId: surfaceID, refreshPorts: false)
        guard model.agentPIDProcessIdentitiesByKey[key] == identity else { return unavailable }
        if model.agentPIDPanelIdsByKey[toolID] == surfaceID, model.agentPIDProcessIdentitiesByKey[toolID] == identity {
            _ = workspace.clearAgentPID(key: toolID, panelId: surfaceID, clearStatus: false, refreshPorts: false)
        }
        // Identity is accepted. Activity remains unknown until a real event arrives.
        return .accepted
    }

    private func resumeKind(_ toolID: String) -> String? {
        switch toolID {
        case "claude_code": return "claude"
        case "codex", "opencode", "commandcode": return toolID
        default: return nil
        }
    }

    private func resumeArguments(kind: String, sessionID: String) -> [String]? {
        // Command Code's native CLI exposes `cmd --resume <id>`; it is never
        // run by binding, and automatic resume remains explicitly disabled.
        if kind == "commandcode" { return ["cmd", "--resume", sessionID] }
        return AgentResumeArgv().builtInKind(kind: kind, sessionId: sessionID, executablePath: nil, arguments: [])
    }

    private func renderedCommand(kind: String, arguments: [String]) -> String {
        if kind == "codex" { return AgentResumeArgv.renderedPortableCodexResumeShellCommand(parts: arguments, quote: SurfaceResumeCommandCanonicalizer.shellQuoted) }
        if kind == "claude" { return AgentResumeArgv.renderedPortableClaudeResumeShellCommand(parts: arguments, quote: SurfaceResumeCommandCanonicalizer.shellQuoted) }
        return arguments.map(SurfaceResumeCommandCanonicalizer.shellQuoted).joined(separator: " ")
    }

    private func birthGeneration(_ identity: AgentPIDProcessIdentity) -> UInt64? {
        guard identity.startSeconds > 0, identity.startMicroseconds >= 0, identity.startMicroseconds < 1_000_000 else { return nil }
        let (seconds, overflow) = UInt64(identity.startSeconds).multipliedReportingOverflow(by: 1_000_000)
        return overflow ? nil : seconds + UInt64(identity.startMicroseconds)
    }

    private var unavailable: CmuxSidebarActionResult {
        .rejected(String(localized: "sidebar.extensions.action.unavailable", defaultValue: "Action is unavailable"))
    }
}
