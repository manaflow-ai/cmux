import CMUXAgentLaunch
import Foundation

/// Localized ownership diagnostics shared by Vault and the restore CLI.
struct CodexWriterRestoreMessage {
    let sessionID: String
    let inspection: CodexWriterRestoreInspection

    var title: String {
        if inspection.lock?.state == .active {
            return String(localized: "sessionIndex.codex.activeWriter.title", defaultValue: "Codex session is already open")
        }
        return String(localized: "sessionIndex.codex.writerCheckUnavailable.title", defaultValue: "Codex session could not be checked")
    }

    var text: String {
        guard let lock = inspection.lock else { return "" }
        if lock.state != .active {
            return String.localizedStringWithFormat(
                String(localized: "codex.restore.writerCheckUnavailable", defaultValue: "cmux could not inspect the Codex writer lock for %@. No new writer was started. Check access to %@, then retry."),
                sessionID, String(reflecting: lock.lockPath)
            )
        }
        let owners = inspection.owners.map { owner in
            String.localizedStringWithFormat(
                String(localized: "codex.restore.writerOwner", defaultValue: "PID %d, working directory %@"),
                owner.pid, String(reflecting: owner.workingDirectory ?? "?")
            )
        }
        let ownerText = owners.isEmpty
            ? String(localized: "codex.restore.writerUnknown", defaultValue: "the owner could not be verified; use lsof to inspect the lock path below")
            : owners.joined(separator: "; ")
        return String.localizedStringWithFormat(
            String(localized: "codex.restore.activeWriter", defaultValue: "Codex session %@ already has an active writer (%@). Continue in its original terminal, or exit that Codex session normally and retry. Lock: %@. cmux did not remove the lock or start another writer."),
            sessionID, ownerText, String(reflecting: lock.lockPath)
        )
    }
}
