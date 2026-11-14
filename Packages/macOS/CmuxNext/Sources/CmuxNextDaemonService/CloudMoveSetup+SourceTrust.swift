public import CmuxNextAgentPane
import CmuxNextCloud

/// A Cloud start from a folder on this Mac (`cmux cloud start-session --from-folder`, `cmux chat --on vm:… --from-folder`)
/// copies it to the machine, and the copy is trusted there only when this Mac trusts the folder (cmux-tui
/// `link start-chat copy`'s `source_trusted`). A folder this Mac does not trust is refused here, before any machine is
/// taken, with the fix on this Mac (live journey, 2026-11-10: the start leased a machine, copied the folder, then failed
/// "… is not a trusted folder on chat-…. Trust it on that machine").
extension CloudMoveSetup {
    /// Why `local` can't start a Cloud chat, before any machine: the folder's own check
    /// (``AgentPaneCloudStart/checkedFolder(_:home:)``, its refusal in the caller's `message`), then this Mac's trust of it
    /// (`link start-chat trust`, read from the acpmux at `acpmuxHome`, the one the copy reads). Nil: it may start. Trust
    /// that can't be read lets it start, as before (the copy reads it again).
    public func refusedSource(_ local: String, home: String, acpmuxHome: String?,
                              message: (AgentPaneCloudFolderRefusal) -> String) async -> String? {
        let checked: String
        switch await AgentPaneCloudStart.checkedFolder(local, home: home) {
        case .failure(let refusal): return message(refusal)
        case .success(let found): checked = found.folder
        }
        guard let cli, let acpmuxHome else { return nil }
        let level = await CloudMoveCLI(binary: cli, timeout: .seconds(15)).startChatTrust(folder: checked, acpmuxHome: acpmuxHome)
        return AgentRemoteStartRefusal.untrustedSource(level: level, folder: checked)?.userMessage
    }
}

nonisolated extension AgentRemoteStartRefusal {
    /// The refusal for this Mac's trust `level` of `folder` (`link start-chat trust`): none when trusted or unread.
    public static func untrustedSource(level: String?, folder: String) -> Self? {
        guard let level, level != "trusted" else { return nil }
        return untrustedSource(folder: folder)
    }

    /// `error`, when it is a machine's refusal of a copy as untrusted (`agent_session.untrusted_folder`), as the refusal
    /// of its source `folder` on this Mac, which this Mac does not trust: the cause and the fix are here, never "on that
    /// machine". Nil for any other error, or with no such folder (a `--cwd` on the machine keeps the machine's words).
    public static func untrustedCopy(_ error: any Error, of folder: String?) -> Self? {
        guard let folder, let refusal = error as? Self, refusal.code == "agent_session.untrusted_folder" else { return nil }
        return untrustedSource(folder: folder, machine: refusal.machine)
    }
}
