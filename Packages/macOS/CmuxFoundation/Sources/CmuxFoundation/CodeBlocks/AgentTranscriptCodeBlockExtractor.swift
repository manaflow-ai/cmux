public import Foundation

/// Pulls the fenced code blocks out of the most recent assistant messages in
/// a Claude Code or Codex transcript (JSONL), so the terminal can offer the
/// exact text the agent wrote instead of what its TUI drew.
public struct AgentTranscriptCodeBlockExtractor: Sendable {
    /// One fence from the transcript, with its copy text.
    public struct Entry: Sendable, Equatable {
        /// The fence as written in the message.
        public let fence: TerminalCodeFence
        /// The block to offer.
        public let block: TerminalCodeBlock
    }

    /// How many trailing assistant messages to scan.
    public let messageLimit: Int

    public init(messageLimit: Int = 12) {
        self.messageLimit = messageLimit
    }

    /// Fences from the last ``messageLimit`` assistant messages in `tail`,
    /// oldest first. `tail` may start mid-line (a byte-range read of the end
    /// of the file); a partial first line fails to parse and is skipped.
    public func entries(fromJSONLTail tail: Data) -> [Entry] {
        let texts = assistantTexts(fromJSONLTail: tail).suffix(messageLimit)
        let parser = TerminalCodeFenceParser()
        let cleaner = TerminalCodeBlockText()
        var result: [Entry] = []
        var seen = Set<String>()
        for text in texts {
            for fence in parser.fences(inMarkdown: text) where fence.closingLine != nil {
                let copyText = cleaner.copyText(for: fence)
                guard !copyText.isEmpty else { continue }
                let block = TerminalCodeBlock(text: copyText, language: fence.infoString, origin: .transcript)
                // A later repeat of the same block wins its screen position.
                if seen.contains(block.id) {
                    result.removeAll { $0.block.id == block.id }
                }
                seen.insert(block.id)
                result.append(Entry(fence: fence, block: block))
            }
        }
        return result
    }

    /// Assistant message texts in file order.
    func assistantTexts(fromJSONLTail tail: Data) -> [String] {
        var texts: [String] = []
        for line in tail.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 2,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let text = Self.assistantText(in: object),
                  !text.isEmpty else { continue }
            texts.append(text)
        }
        return texts
    }

    private static func assistantText(in object: [String: Any]) -> String? {
        switch object["type"] as? String {
        case "assistant":
            // Claude Code: {"type":"assistant","message":{"content":[{"type":"text","text":...}]}}
            if object["isSidechain"] as? Bool == true { return nil }
            guard let message = object["message"] as? [String: Any] else { return nil }
            return joinedText(message["content"], textTypes: ["text"])
        case "response_item":
            // Codex: {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text",...}]}}
            guard let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "assistant" else { return nil }
            return joinedText(payload["content"], textTypes: ["output_text", "text"])
        default:
            return nil
        }
    }

    private static func joinedText(_ content: Any?, textTypes: Set<String>) -> String? {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part -> String? in
            guard let type = part["type"] as? String, textTypes.contains(type) else { return nil }
            return part["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}
