import CmuxAgentReplica
import CmuxAgentTruthKit
import Foundation

struct AgentGUITranscriptDecoderBox: Sendable {
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

struct AgentGUITranscriptDecodedSourceLine: Sendable {
    let sourceLine: AgentGUIJournalSourceLine
    let batch: TranscriptDecodeBatch
    let toolCallIDs: Set<String>
}

/// Owns stateful transcript decoders away from the main actor. Large image
/// records therefore cannot block scrolling while JSON and base64 metadata are
/// parsed.
actor AgentGUITranscriptDecodeWorker {
    private let kind: AgentKind
    private var decoder: AgentGUITranscriptDecoderBox

    init(kind: AgentKind) {
        self.kind = kind
        self.decoder = AgentGUITranscriptDecoderBox(kind: kind)
    }

    func reset() {
        decoder = AgentGUITranscriptDecoderBox(kind: kind)
    }

    func feed(
        _ sourceLines: [AgentGUIJournalSourceLine],
        journalID: JournalID
    ) -> [AgentGUITranscriptDecodedSourceLine] {
        sourceLines.map { sourceLine in
            AgentGUITranscriptDecodedSourceLine(
                sourceLine: sourceLine,
                batch: decoder.feed(
                    [sourceLine.text],
                    startingAt: sourceLine.startOffset,
                    journalID: journalID
                ),
                toolCallIDs: AgentGUIJournalToolCorrelation.callIDs(in: sourceLine.text)
            )
        }
    }
}
