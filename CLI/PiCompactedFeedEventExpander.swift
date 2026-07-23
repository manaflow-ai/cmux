import Foundation

/// Expands a bounded Pi terminal-event batch into ordinary Feed socket requests.
struct PiCompactedFeedEventExpander {
    private static let maxCompactedTerminalEvents = 64
    private let agentPid: Int
    private let workspaceId: String?
    private let surfaceId: String?
    private let maximumRequestCount: Int

    init(
        agentPid: Int,
        workspaceId: String?,
        surfaceId: String?,
        maximumRequestCount: Int? = nil
    ) {
        self.agentPid = agentPid
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.maximumRequestCount = min(
            max(1, maximumRequestCount ?? Self.maxCompactedTerminalEvents),
            Self.maxCompactedTerminalEvents
        )
    }

    func requestLines(from rawObject: [String: Any]) -> [String] {
        guard let summaries = rawObject["cmux_compacted_terminal_events"] as? [[String: Any]],
              !summaries.isEmpty,
              summaries.count <= Self.maxCompactedTerminalEvents
        else {
            return []
        }

        let rawOmittedCount = rawObject["cmux_compacted_terminal_omitted_count"] as? Int ?? 0
        let omittedCount = max(0, rawOmittedCount)
        let needsOverflow = omittedCount > 0 || summaries.count > maximumRequestCount
        let retainedSummaryLimit = needsOverflow
            ? maximumRequestCount - 1
            : maximumRequestCount
        let retainedSummaries: [[String: Any]]
        if summaries.count <= retainedSummaryLimit {
            retainedSummaries = summaries
        } else {
            let leadingCount = retainedSummaryLimit / 2
            let trailingCount = retainedSummaryLimit - leadingCount
            retainedSummaries = Array(summaries.prefix(leadingCount))
                + Array(summaries.suffix(trailingCount))
        }
        var requests = retainedSummaries.enumerated().compactMap { index, summary in
            requestLine(summary: summary, fallback: rawObject, index: index)
        }
        if needsOverflow {
            let displacedCount = summaries.count - retainedSummaries.count
            let (representedOmittedCount, overflowed) = omittedCount.addingReportingOverflow(displacedCount)
            var summary: [String: Any] = [
                "tool_call_id": "compacted-omitted-\(overflowed ? Int.max : representedOmittedCount)",
                "tool_name": "cmux_compacted_terminal_overflow",
                "tool_result": ["omitted_terminal_count": overflowed ? Int.max : representedOmittedCount],
            ]
            summary["session_id"] = rawObject["session_id"]
            summary["turn_id"] = rawObject["turn_id"]
            if let request = requestLine(summary: summary, fallback: rawObject, index: retainedSummaries.count) {
                requests.append(request)
            }
        }
        return requests
    }

    private func requestLine(
        summary: [String: Any],
        fallback: [String: Any],
        index: Int
    ) -> String? {
        guard let sessionId = string(summary["session_id"]) ?? string(fallback["session_id"]) else {
            return nil
        }
        let toolCallId = string(summary["tool_call_id"]) ?? "compacted-\(index)"
        let requestId = "pi-\(sessionId)-PostToolUse-\(toolCallId)-compacted-\(index)"
        var event: [String: Any] = [
            "session_id": "pi-\(sessionId)",
            "hook_event_name": "PostToolUse",
            "_source": "pi",
            "_ppid": agentPid,
            "_opencode_request_id": requestId,
        ]
        if let workspaceId {
            event["workspace_id"] = workspaceId
        }
        if let surfaceId {
            event["surface_id"] = surfaceId
        }
        if let cwd = string(summary["cwd"]) ?? string(fallback["cwd"]) {
            event["cwd"] = cwd
        }
        if let turnId = string(summary["turn_id"]) ?? string(fallback["turn_id"]) {
            event["turn_id"] = turnId
        }
        event["tool_call_id"] = toolCallId
        if let toolName = string(summary["tool_name"]) {
            event["tool_name"] = toolName
        }
        if let isError = summary["is_error"] as? Bool {
            event["is_error"] = isError
        }
        if let toolResult = summary["tool_result"] {
            event["tool_input"] = terminalResultMetadata(toolResult)
        }

        let request: [String: Any] = [
            "id": requestId,
            "method": "feed.push",
            "params": [
                "event": event,
                "wait_timeout_seconds": 0,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private func terminalResultMetadata(_ result: Any) -> [String: Any] {
        if result is NSNull {
            return ["kind": "null"]
        }
        if let value = result as? String {
            return ["kind": "text", "length": value.count]
        }
        if result is Bool {
            return ["kind": "boolean"]
        }
        if result is NSNumber {
            return ["kind": "number"]
        }
        if let value = result as? [Any] {
            return ["kind": "array", "count": value.count]
        }
        guard let value = result as? [String: Any] else {
            return ["kind": "unknown"]
        }

        var metadata: [String: Any] = [:]
        let allowedKinds = Set(["null", "text", "boolean", "number", "array", "object", "undefined"])
        if let kind = string(value["kind"]), allowedKinds.contains(kind) {
            metadata["kind"] = kind
        }
        for key in ["length", "count", "key_count", "omitted_terminal_count"] {
            if let count = value[key] as? Int, count >= 0 {
                metadata[key] = count
            }
        }
        if metadata.isEmpty {
            metadata = ["kind": "object", "key_count": value.count]
        }
        return metadata
    }
}
