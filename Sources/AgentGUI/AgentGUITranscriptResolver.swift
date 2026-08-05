import CmuxAgentReplica
import CmuxAgentTruthKit
import Foundation

struct AgentGUITranscriptResolver {
    func transcriptPath(sessionID: AgentSessionID, kind: AgentKind, cwd: String?, evidencePath: String?) -> String? {
        if let evidencePath = evidencePath?.nilIfBlank {
            return evidencePath
        }
        guard case .claude = kind, let cwd = cwd?.nilIfBlank else {
            return nil
        }
        let project = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return NSHomeDirectory()
            .appending("/.claude/projects/")
            .appending(project)
            .appending("/")
            .appending(sessionID.rawValue)
            .appending(".jsonl")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
