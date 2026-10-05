import CMUXAgentLaunch
import CmuxAgentJournal
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
              let kind = resumeKind(toolID) else { return unavailable }
        let statusKey = AgentSemanticEventMapper().statusKey(nativeToolID: toolID)
        let model = workspace.sidebarAgentRuntimeObservation
        let candidates = Set((model.agentPIDKeysByPanelId[surfaceID] ?? []).compactMap { key -> AgentPIDProcessIdentity? in
            guard AgentSemanticEventMapper().statusKey(nativeToolID: workspace.agentStatusKey(forAgentPIDKey: key)) == statusKey,
                  model.agentPIDPanelIdsByKey[key] == surfaceID,
                  let pid = model.agentPIDs[key], let identity = model.agentPIDProcessIdentitiesByKey[key],
                  identity.pid == pid, processIdentity(pid) == identity else { return nil }
            return identity
        })
        guard candidates.count == 1, let identity = candidates.first,
              birthGeneration(identity) == generation,
              ownsSurface(identity.pid, workspaceID, surfaceID) else { return unavailable }
        let previous: SurfaceResumeBindingSnapshot? = workspace.surfaceResumeBinding(panelId: surfaceID).flatMap {
            guard resumeKind($0.kind ?? "") == kind, let previousSID = $0.checkpointId,
                  model.agentPIDKeysByPanelId[surfaceID]?.contains(where: { key in
                      let nativeTool = workspace.agentStatusKey(forAgentPIDKey: key)
                      return AgentSemanticEventMapper().statusKey(nativeToolID: nativeTool) == statusKey
                          && key == nativeTool + "." + previousSID && model.agentPIDProcessIdentitiesByKey[key] == identity
                  }) == true else { return nil }
            return $0
        }
        guard let argv = resumeArguments(kind: kind, sessionID: sessionID, previous: previous) else { return unavailable }
        var binding = previous ?? SurfaceResumeBindingSnapshot(name: kind, kind: kind,
            command: renderedCommand(kind: kind, arguments: argv), cwd: workspace.currentDirectory)
        binding.command = renderedCommand(kind: kind, arguments: argv)
        binding.checkpointId = sessionID
        binding.source = "user-sidebar"
        binding.autoResume = false
        binding.updatedAt = now().timeIntervalSince1970
        guard workspace.setSurfaceResumeBinding(binding, panelId: surfaceID) else { return unavailable }
        let key = statusKey + "." + sessionID
        _ = workspace.recordAgentPID(key: key, pid: identity.pid, panelId: surfaceID, refreshPorts: false)
        guard model.agentPIDProcessIdentitiesByKey[key] == identity else { return unavailable }
        for alias in Set([toolID, statusKey]) where model.agentPIDPanelIdsByKey[alias] == surfaceID && model.agentPIDProcessIdentitiesByKey[alias] == identity {
            _ = workspace.clearAgentPID(key: alias, panelId: surfaceID, clearStatus: false, refreshPorts: false)
        }
        // Identity is accepted. Activity remains unknown until a real event arrives.
        return .accepted
    }

    private func resumeKind(_ toolID: String) -> String? {
        switch toolID {
        case "claude", "claude_code": return "claude"
        case "codex", "opencode", "commandcode": return toolID
        default: return nil
        }
    }

    private func resumeArguments(kind: String, sessionID: String, previous: SurfaceResumeBindingSnapshot?) -> [String]? {
        let launch = previous?.launchCommand
        if let launch, launch.isRejectedCapture || AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(launch.arguments)
            || !AgentLaunchCaptureTrust.launcherDescribesKind(launch.launcher, kind: kind) { return nil }
        if kind == "commandcode" {
            // A restricted managed launch must never degrade to a raw `cmd` restore.
            // Broader custom argv needs its provider's typed resume policy first.
            guard let executable = launch?.arguments.first,
                  (executable as NSString).lastPathComponent == "commandcode-clean",
                  launch?.executablePath == nil || launch?.executablePath == executable,
                  launch?.arguments.count == 1 || (launch?.arguments.count == 3 && ["-r", "--resume"].contains(launch?.arguments[1] ?? "")) else { return nil }
            return [executable, "--resume", sessionID]
        }
        let builder = AgentResumeArgv()
        switch builder.launcherResolution(launcher: launch?.launcher, sessionId: sessionID, executablePath: launch?.executablePath, arguments: launch?.arguments ?? [], environment: launch?.environment) {
        case .resolved(let argv): return argv
        case .passthrough: break
        }
        return builder.builtInKind(kind: kind, sessionId: sessionID, executablePath: launch?.executablePath, arguments: launch?.arguments ?? [], observedPermissionMode: previous?.permissionMode)
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
