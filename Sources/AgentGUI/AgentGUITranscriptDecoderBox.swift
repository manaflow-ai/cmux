import CmuxAgentReplica
import CmuxAgentTruthKit
import Foundation

struct AgentGUITranscriptDecoderBox {
    private var claude: ClaudeTranscriptDecoder?
    private var codex: CodexTranscriptDecoder?

    init(kind: AgentKind) {
        switch kind {
        case .claude:
            self.claude = ClaudeTranscriptDecoder()
            self.codex = nil
        case .codex:
            self.claude = nil
            self.codex = CodexTranscriptDecoder()
        case .unknown:
            self.claude = ClaudeTranscriptDecoder()
            self.codex = nil
        }
    }

    mutating func feed(_ lines: [String], startingAt: Int, journalID: JournalID) -> TranscriptDecodeBatch {
        if var decoder = claude {
            let batch = decoder.feed(lines, startingAt: startingAt, journalID: journalID)
            claude = decoder
            return batch
        }
        if var decoder = codex {
            let batch = decoder.feed(lines, startingAt: startingAt, journalID: journalID)
            codex = decoder
            return batch
        }
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: startingAt, journalID: journalID)
        claude = decoder
        return batch
    }
}
