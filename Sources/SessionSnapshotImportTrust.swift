import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

/// What `SessionSnapshotImportTrust` removed or held back from an imported
/// session file.
struct SessionSnapshotImportTrustReport: Equatable, Sendable {
    /// Terminals whose resume command will not run automatically: custom
    /// agent registrations, trusted-source resume bindings, and tmux start
    /// commands taken from the file.
    var heldBackResumeCount = 0
    /// Workspaces whose SSH/cloud connection or environment was dropped.
    var droppedRemoteWorkspaceCount = 0
}

/// Restore policy for a session snapshot read from an arbitrary file
/// (`cmux restore-session --from <path>`).
///
/// A file can carry anything, so nothing in it may run automatically on the
/// user's machine. Mirrors the policy for public CLI/socket-created surface
/// resume bindings: layout, working directories, scrollback, and browser
/// state restore normally; command-bearing state is either reconstructed by
/// cmux from known values or kept for manual restore.
///
/// - Built-in agents (a known `RestorableAgentKind`, or a built-in Vault
///   registration id) are rebuilt from kind, session id, and working
///   directory only. Launch argv, permission mode, and registration content
///   from the file are discarded, so the resume command is the one cmux
///   generates for that agent.
/// - Custom agent registrations stay attached for manual restore, but the
///   terminal is marked as not running an agent so nothing auto-resumes.
/// - Resume bindings lose trusted sources (`agent-hook`,
///   `process-detected`) and any stored approval, so they go through the
///   signed approved-prefix check like a CLI-created binding and otherwise
///   stay manual. A hook binding already covered by a rebuilt built-in agent
///   is dropped.
/// - tmux start commands are dropped.
/// - Workspace SSH/cloud connections and workspace environment variables are
///   dropped (SSH options such as `ProxyCommand` and variables such as
///   `BASH_ENV` execute locally).
///
/// Snapshots read from another install's own session file (a channel import)
/// keep full trust and do not go through this.
enum SessionSnapshotImportTrust {
    /// Built-in Vault registrations, keyed by id. File content is never used
    /// for these; the app's own definition replaces it.
    static var builtInRegistrationsByID: [String: CmuxVaultAgentRegistration] {
        let builtIns: [CmuxVaultAgentRegistration] = [
            .builtInPi,
            .builtInOmp,
            .builtInCampfire,
            .builtInAmp,
            .builtInAntigravity,
            .builtInGrok,
            .builtInKimi,
            .builtInHermes,
        ]
        return Dictionary(builtIns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The snapshot to restore for an import from `source`: unchanged for
    /// another install's own session file, sanitized for an arbitrary file.
    static func snapshotForRestore(
        _ snapshot: AppSessionSnapshot,
        source: ControlSessionImportSource
    ) -> (snapshot: AppSessionSnapshot, report: SessionSnapshotImportTrustReport) {
        source.isTrusted
            ? (snapshot, SessionSnapshotImportTrustReport())
            : sanitizingUntrustedImport(snapshot)
    }

    static func sanitizingUntrustedImport(
        _ snapshot: AppSessionSnapshot
    ) -> (snapshot: AppSessionSnapshot, report: SessionSnapshotImportTrustReport) {
        var report = SessionSnapshotImportTrustReport()
        var sanitized = snapshot
        let builtIns = builtInRegistrationsByID
        for windowIndex in sanitized.windows.indices {
            var window = sanitized.windows[windowIndex]
            for workspaceIndex in window.tabManager.workspaces.indices {
                var workspace = window.tabManager.workspaces[workspaceIndex]
                if workspace.remote != nil || workspace.cloudVM != nil || workspace.environment?.isEmpty == false {
                    report.droppedRemoteWorkspaceCount += 1
                }
                workspace.remote = nil
                workspace.cloudVM = nil
                workspace.environment = nil
                workspace.panels = workspace.panels.map {
                    sanitizedPanel($0, builtIns: builtIns, report: &report)
                }
                if var dock = workspace.dock {
                    dock.panels = dock.panels.map { sanitizedPanel($0, builtIns: builtIns, report: &report) }
                    workspace.dock = dock
                }
                window.tabManager.workspaces[workspaceIndex] = workspace
            }
            if var dock = window.dock {
                dock.panels = dock.panels.map { sanitizedPanel($0, builtIns: builtIns, report: &report) }
                window.dock = dock
            }
            sanitized.windows[windowIndex] = window
        }
        return (sanitized, report)
    }

    private static func sanitizedPanel(
        _ panel: SessionPanelSnapshot,
        builtIns: [String: CmuxVaultAgentRegistration],
        report: inout SessionSnapshotImportTrustReport
    ) -> SessionPanelSnapshot {
        guard var terminal = panel.terminal else { return panel }
        var panel = panel
        var heldBack = false

        var rebuiltAgent: SessionRestorableAgentSnapshot?
        if let agent = terminal.agent {
            if let rebuilt = rebuiltBuiltInAgent(agent, builtIns: builtIns) {
                rebuiltAgent = rebuilt
                terminal.agent = rebuilt
            } else {
                // Custom registration or an unsafe session id: keep it for
                // manual restore, never auto-resume it.
                heldBack = heldBack || terminal.wasAgentRunning != false
                terminal.wasAgentRunning = false
            }
        }

        let (binding, bindingHeldBack) = sanitizedBinding(terminal.resumeBinding, coveredBy: rebuiltAgent)
        terminal.resumeBinding = binding
        let (managed, managedHeldBack) = sanitizedBinding(terminal.managedAgentResumeBinding, coveredBy: rebuiltAgent)
        terminal.managedAgentResumeBinding = managed
        heldBack = heldBack || bindingHeldBack || managedHeldBack

        if terminal.tmuxStartCommand != nil {
            terminal.tmuxStartCommand = nil
            heldBack = true
        }
        if heldBack {
            report.heldBackResumeCount += 1
        }
        panel.terminal = terminal
        return panel
    }

    /// Rebuilds a built-in agent from its kind, session id, and working
    /// directory only, or returns nil when the agent is not built-in or its
    /// session id is not a single safe token.
    static func rebuiltBuiltInAgent(
        _ agent: SessionRestorableAgentSnapshot,
        builtIns: [String: CmuxVaultAgentRegistration] = builtInRegistrationsByID
    ) -> SessionRestorableAgentSnapshot? {
        guard AgentRestoreCLIArgument(rawValue: agent.sessionId) != nil else { return nil }
        let registration: CmuxVaultAgentRegistration?
        if let fileRegistration = agent.registration {
            guard let builtIn = builtIns[fileRegistration.id],
                  agent.kind.rawValue == builtIn.id else {
                return nil
            }
            registration = builtIn
        } else {
            if case .custom(let id) = agent.kind {
                guard let builtIn = builtIns[id] else { return nil }
                registration = builtIn
            } else {
                registration = nil
            }
        }
        return SessionRestorableAgentSnapshot(
            kind: agent.kind,
            sessionId: agent.sessionId,
            workingDirectory: agent.workingDirectory,
            launchCommand: nil,
            registration: registration
        )
    }

    /// Strips trust from a file-provided binding. Returns the binding to keep
    /// (nil when a rebuilt built-in agent already covers it) and whether an
    /// automatic resume was held back.
    private static func sanitizedBinding(
        _ binding: SurfaceResumeBindingSnapshot?,
        coveredBy rebuiltAgent: SessionRestorableAgentSnapshot?
    ) -> (SurfaceResumeBindingSnapshot?, Bool) {
        guard var binding else { return (nil, false) }
        if binding.isAgentHookBinding,
           let rebuiltAgent,
           binding.checkpointId == rebuiltAgent.sessionId,
           binding.kind == nil || binding.kind == rebuiltAgent.kind.rawValue {
            return (nil, false)
        }
        let couldAutoRun = binding.isAgentHookBinding || binding.isProcessDetected || binding.autoResume == true
        if binding.isAgentHookBinding || binding.isProcessDetected {
            binding.source = "cli"
        }
        binding.autoResume = false
        binding.approvalPolicy = .manual
        binding.approvalRecordId = nil
        binding.resumeEvidenceProvenance = nil
        return (binding, couldAutoRun)
    }
}
