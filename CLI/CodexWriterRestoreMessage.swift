import CMUXAgentLaunch
import Foundation

/// Localized diagnostics for a restore blocked by Codex's writer protocol.
struct CodexWriterRestoreMessage {
    let inspection: CodexWriterLockInspection
    let candidates: [CodexWriterProcessInspector.Candidate]

    var text: String {
        guard inspection.state == .active else {
            return String(localized: "codex.restore.writerCheckUnavailable", defaultValue: "cmux could not verify the Codex session owner. No new writer was started. Check the Codex account configuration, then retry 'cmux restore --surface'.")
        }
        let message = String(localized: "codex.restore.activeWriter", defaultValue: "This Codex conversation still has an active writer in another process. Continue there, or close it normally and retry 'cmux restore --surface'. cmux did not start another writer.")
        guard !candidates.isEmpty else { return message }
        let format = String(localized: "codex.restore.writerCandidates", defaultValue: "Processes observed with this conversation's lock file open: %1$@. An open file alone does not prove which process owns the lock.")
        let processes = candidates.map { "\($0.pid) (\($0.executable))" }.joined(separator: ", ")
        return message + "\n" + String(format: format, locale: Locale(identifier: "en_US_POSIX"), processes)
    }
}
