import Foundation

extension RestorableAgentSessionIndex {
    /// Whether this load saw a Claude hook record for `sessionId`, found no
    /// transcript for it in any config root, and Claude still has not written
    /// one at the paths it reported. The re-check covers a first prompt sent
    /// after this index loaded; it stats at most a few files per session.
    func claudeSessionLacksTranscript(_ sessionId: String?) -> Bool {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty,
              let expectedPaths = claudeTranscriptPathsBySessionWithoutTranscript[sessionId] else {
            return false
        }
        return !expectedPaths.contains(where: Self.regularNonEmptyFileExists(atPath:))
    }

    /// Drops the Claude resume state a saved terminal would replay when Claude
    /// never wrote that session's transcript (it was quit before its first
    /// prompt). Resuming it fails with "No conversation found", so the tab
    /// reopens as a plain shell. Applied after the snapshot is built so an
    /// older session on the same surface is never promoted in its place.
    func removingTranscriptlessClaudeResume(
        from terminal: SessionTerminalPanelSnapshot
    ) -> SessionTerminalPanelSnapshot {
        guard !claudeTranscriptPathsBySessionWithoutTranscript.isEmpty else { return terminal }
        var terminal = terminal
        if let agent = terminal.agent,
           agent.kind == .claude,
           claudeSessionLacksTranscript(agent.sessionId) {
            terminal.agent = nil
            terminal.hibernation = nil
        }
        if bindingResumesTranscriptlessClaude(terminal.resumeBinding) {
            terminal.resumeBinding = nil
        }
        if bindingResumesTranscriptlessClaude(terminal.managedAgentResumeBinding) {
            terminal.managedAgentResumeBinding = nil
        }
        return terminal
    }

    /// Applies ``removingTranscriptlessClaudeResume(from:)`` to every terminal panel.
    func removingTranscriptlessClaudeResume(
        from panels: [SessionPanelSnapshot]
    ) -> [SessionPanelSnapshot] {
        guard !claudeTranscriptPathsBySessionWithoutTranscript.isEmpty else { return panels }
        return panels.map { panel in
            guard let terminal = panel.terminal else { return panel }
            var panel = panel
            panel.terminal = removingTranscriptlessClaudeResume(from: terminal)
            return panel
        }
    }

    private static func regularNonEmptyFileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private func bindingResumesTranscriptlessClaude(
        _ binding: SurfaceResumeBindingSnapshot?
    ) -> Bool {
        guard let binding, binding.isAgentHookBinding,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == RestorableAgentKind.claude.rawValue else {
            return false
        }
        return claudeSessionLacksTranscript(binding.checkpointId)
    }
}
