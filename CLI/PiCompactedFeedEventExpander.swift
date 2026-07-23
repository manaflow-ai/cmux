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

    func acknowledgedBatchRequest(from rawObject: [String: Any]) -> (line: String, eventCount: Int)? {
        let events = events(from: rawObject)
        guard let firstRequestId = events.first?["_opencode_request_id"] as? String else { return nil }
        let request: [String: Any] = [
            "id": "\(firstRequestId)-batch",
            "method": "feed.push",
            "params": [
                "events": events,
                "wait_timeout_seconds": 0,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        return (line, events.count)
    }

    private func events(from rawObject: [String: Any]) -> [[String: Any]] {
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
        var events = retainedSummaries.enumerated().compactMap { index, summary in
            event(summary: summary, fallback: rawObject, index: index)
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
            if let event = event(summary: summary, fallback: rawObject, index: retainedSummaries.count) {
                events.append(event)
            }
        }
        return events
    }

    private func event(
        summary: [String: Any],
        fallback: [String: Any],
        index: Int
    ) -> [String: Any]? {
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
            event["tool_input"] = CMUXCLI.sanitizedPiPostToolUseFeedValue(toolResult)
        }

        return event
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}
