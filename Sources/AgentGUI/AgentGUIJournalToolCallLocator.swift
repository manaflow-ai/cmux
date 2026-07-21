import Foundation

enum AgentGUIJournalToolCorrelation {
    static func callIDs(in line: String) -> Set<String> {
        guard let root = object(in: line) else { return [] }
        let payload = (root["payload"] as? [String: Any]) ?? root
        if root["type"] as? String == "response_item",
           let type = payload["type"] as? String,
           ["function_call", "custom_tool_call", "web_search_call", "tool_search_call"].contains(type),
           let callID = payload["call_id"] as? String {
            return [callID]
        }
        return Set(claudeBlocks(in: root).compactMap { block in
            guard block["type"] as? String == "tool_use" else { return nil }
            return block["id"] as? String
        })
    }

    static func resultIDs(in line: String) -> Set<String> {
        guard let root = object(in: line) else { return [] }
        let payload = (root["payload"] as? [String: Any]) ?? root
        if root["type"] as? String == "response_item",
           let type = payload["type"] as? String,
           ["function_call_output", "custom_tool_call_output", "tool_search_output"].contains(type),
           let callID = payload["call_id"] as? String {
            return [callID]
        }
        return Set(claudeBlocks(in: root).compactMap { block in
            guard block["type"] as? String == "tool_result" else { return nil }
            return block["tool_use_id"] as? String
        })
    }

    private static func object(in line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return value as? [String: Any]
    }

    private static func claudeBlocks(in root: [String: Any]) -> [[String: Any]] {
        let message = root["message"] as? [String: Any]
        return message?["content"] as? [[String: Any]] ?? []
    }
}

/// Finds source tool calls for result rows that begin outside the bounded
/// decoder overlap. It scans backward in bounded blocks and never loads a
/// journal-sized buffer.
enum AgentGUIJournalToolCallLocator {
    struct Result: Sendable {
        let linesByCallID: [String: AgentGUIJournalSourceLine]
        let scannedByteCount: Int
        let pageCount: Int
    }

    static let scanByteCap = 4 * 1_024 * 1_024
    static let scanPageCap = 8
    private static let pageByteCap = 1 * 1_024 * 1_024
    private static let pageLineCap = 4_096

    static func locate(
        callIDs: Set<String>,
        path: String,
        before offset: Int
    ) -> Result {
        var unresolved = callIDs
        var found: [String: AgentGUIJournalSourceLine] = [:]
        var boundary = offset
        var scannedByteCount = 0
        var pageCount = 0
        while !unresolved.isEmpty,
              boundary > 0,
              scannedByteCount < scanByteCap,
              pageCount < scanPageCap {
            let remainingBytes = scanByteCap - scannedByteCount
            let page = AgentGUIJournalPageReader.read(
                path: path,
                direction: .before(boundary),
                lineLimit: pageLineCap,
                byteLimit: min(pageByteCap, remainingBytes),
                recoversOversizedRecords: false
            )
            guard page.readSucceeded, page.startOffset < boundary else { break }
            pageCount += 1
            scannedByteCount += boundary - page.startOffset
            for line in page.lines.reversed() {
                for callID in AgentGUIJournalToolCorrelation.callIDs(in: line.text)
                    where unresolved.contains(callID) {
                    found[callID] = line
                    unresolved.remove(callID)
                }
            }
            boundary = page.startOffset
        }
        return Result(
            linesByCallID: found,
            scannedByteCount: scannedByteCount,
            pageCount: pageCount
        )
    }
}
