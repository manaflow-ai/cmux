import Foundation

extension AgentHibernationTranscriptGuard {
    /// How much of the transcript tail is scanned for background launches. A
    /// launch older than this window is not seen here; the process-scope check
    /// still keeps panes with live background shells awake.
    static let backgroundWorkScanTailBytes = 32 * 1024 * 1024

    /// Whether the Claude transcript records background work that has not
    /// reported completion: a `run_in_background` Bash command, a Monitor, or an
    /// async Agent. Claude writes the launch as a tool result carrying
    /// `toolUseResult.backgroundTaskId`, `toolUseResult.taskId`, or
    /// `toolUseResult.isAsync` with status `async_launched`, and the completion as
    /// a `<task-notification>` naming the same `<tool-use-id>` with a `<status>`.
    /// Launches before `notBefore` (the agent process start) belong to an earlier
    /// process whose background work died with it, so they are ignored.
    static func transcriptHasUnfinishedBackgroundWork(
        atPath path: String,
        notBefore: Date? = nil,
        maxTailBytes: Int = Self.backgroundWorkScanTailBytes
    ) -> Bool {
        guard let data = tailData(atPath: path, maxBytes: maxTailBytes) else { return false }
        return unfinishedBackgroundLaunchIDs(inTranscriptTail: data, notBefore: notBefore).isEmpty == false
    }

    static func unfinishedBackgroundLaunchIDs(
        inTranscriptTail data: Data,
        notBefore: Date?
    ) -> Set<String> {
        var launches: [BackgroundLaunch] = []
        var finishedIDs: Set<String> = []
        let launchMarkers = ["\"backgroundTaskId\"", "\"async_launched\"", "\"timeoutMs\"", "\"task_id\""]
            .map { Data($0.utf8) }
        let notificationMarker = Data("<task-notification>".utf8)
        let timestamps = TranscriptTimestampParser()
        for line in data.split(separator: 10, omittingEmptySubsequences: true) {
            let hasLaunch = launchMarkers.contains { line.range(of: $0) != nil }
            let hasNotification = line.range(of: notificationMarker) != nil
            guard hasLaunch || hasNotification,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }
            if hasLaunch, let lineLaunches = backgroundLaunches(in: object) {
                let launchedBeforeAgent = notBefore.flatMap { notBefore in
                    timestamps.date(object["timestamp"]).map { $0 < notBefore }
                } ?? false
                if !launchedBeforeAgent {
                    launches.append(contentsOf: lineLaunches)
                }
            }
            if hasLaunch, let stoppedTaskID = stoppedTaskID(in: object) {
                finishedIDs.insert(stoppedTaskID)
            }
            if hasNotification {
                for text in taskNotificationCarrierTexts(in: object) {
                    finishedIDs.formUnion(finishedTaskIDs(inNotificationText: text))
                }
            }
        }
        return Set(launches.filter { launch in
            !finishedIDs.contains(launch.toolUseID) &&
                !(launch.taskID.map(finishedIDs.contains) ?? false)
        }.map(\.toolUseID))
    }

    private struct BackgroundLaunch {
        let toolUseID: String
        let taskID: String?
    }

    /// Launches recorded by a user line whose tool result started background work.
    private static func backgroundLaunches(in object: [String: Any]) -> [BackgroundLaunch]? {
        guard let result = object["toolUseResult"] as? [String: Any] else { return nil }
        let taskID: String?
        if let id = nonEmptyString(result["backgroundTaskId"]) {
            taskID = id
        } else if let id = nonEmptyString(result["taskId"]),
                  result["timeoutMs"] != nil || result["persistent"] != nil {
            // Monitor. Other tools also return a `taskId` (todo updates), so the
            // Monitor-only keys are required.
            taskID = id
        } else if (result["isAsync"] as? Bool) == true,
                  (result["status"] as? String) == "async_launched" {
            taskID = nonEmptyString(result["agentId"])
        } else {
            return nil
        }
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }
        let launches = content.compactMap { block -> BackgroundLaunch? in
            guard block["type"] as? String == "tool_result",
                  let id = nonEmptyString(block["tool_use_id"]) else {
                return nil
            }
            return BackgroundLaunch(toolUseID: id, taskID: taskID)
        }
        return launches.isEmpty ? nil : launches
    }

    /// The task a TaskStop result reports as stopped. A stopped task does not
    /// always leave a terminal notification behind.
    private static func stoppedTaskID(in object: [String: Any]) -> String? {
        guard let result = object["toolUseResult"] as? [String: Any],
              result["task_type"] != nil else {
            return nil
        }
        return nonEmptyString(result["task_id"])
    }

    /// The places Claude records a delivered or queued task notification. Tool
    /// results that merely quote notification text are deliberately not read.
    private static func taskNotificationCarrierTexts(in object: [String: Any]) -> [String] {
        switch object["type"] as? String {
        case "queue-operation":
            return [object["content"] as? String].compactMap { $0 }
        case "attachment":
            let attachment = object["attachment"] as? [String: Any]
            return [attachment?["prompt"] as? String].compactMap { $0 }
        case "user":
            let message = object["message"] as? [String: Any]
            if let text = message?["content"] as? String {
                return [text]
            }
            let blocks = message?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { block in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }
        default:
            return []
        }
    }

    /// Tool-use and task ids named by terminal task notifications in `text`.
    /// One notification can close several tasks ("4 background agents
    /// stopped"). Monitor event notifications carry no `<status>` and do not end
    /// the task.
    static func finishedTaskIDs(inNotificationText text: String) -> [String] {
        var ids: [String] = []
        var remainder = text[...]
        while let start = remainder.range(of: "<task-notification>") {
            let afterStart = remainder[start.upperBound...]
            let end = afterStart.range(of: "</task-notification>")
            let body = end.map { afterStart[..<$0.lowerBound] } ?? afterStart
            if body.contains("<status>") {
                ids.append(contentsOf: tagValues("tool-use-id", in: body))
                ids.append(contentsOf: tagValues("task-id", in: body))
            }
            remainder = end.map { afterStart[$0.upperBound...] } ?? afterStart[afterStart.endIndex...]
        }
        return ids
    }

    private static func tagValues(_ tag: String, in text: Substring) -> [String] {
        var values: [String] = []
        var remainder = text
        while let open = remainder.range(of: "<\(tag)>"),
              let close = remainder[open.upperBound...].range(of: "</\(tag)>") {
            let value = remainder[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values.append(value)
            }
            remainder = remainder[close.upperBound...]
        }
        return values
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private struct TranscriptTimestampParser {
        private let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private let whole = ISO8601DateFormatter()

        func date(_ value: Any?) -> Date? {
            guard let string = value as? String else { return nil }
            return fractional.date(from: string) ?? whole.date(from: string)
        }
    }

    /// The last `maxBytes` of the file, starting at a line boundary.
    private static func tailData(atPath path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: start)
            guard var data = try handle.readToEnd() else { return Data() }
            if start > 0, let newline = data.firstIndex(of: 10) {
                data = data[data.index(after: newline)...]
            }
            return Data(data)
        } catch {
            return nil
        }
    }
}
