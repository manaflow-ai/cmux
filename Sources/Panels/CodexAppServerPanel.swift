import Foundation
import Combine

#if DEBUG
enum CodexAppServerTiming {
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMs(since start: UInt64) -> Double {
        Double(now() - start) / 1_000_000
    }

    static func log(_ name: String, _ fields: [String: Any?] = [:]) {
        let fieldPriority: [String: Int] = [
            "ms": 0,
            "mode": 1,
            "items": 2,
            "entries": 3,
            "total": 4,
            "exact_total": 5,
            "truncated": 6,
            "bytes": 7,
            "read_mb": 8,
            "file_mb": 9,
        ]
        let fieldText = fields
            .sorted {
                let lhs = fieldPriority[$0.key] ?? 100
                let rhs = fieldPriority[$1.key] ?? 100
                if lhs != rhs { return lhs < rhs }
                return $0.key < $1.key
            }
            .map { key, value in "\(key)=\(format(value))" }
            .joined(separator: " ")
        if fieldText.isEmpty {
            cmuxDebugLog("codex.load.\(name)")
        } else {
            cmuxDebugLog("codex.load.\(name) \(fieldText)")
        }
    }

    static func logSlow(
        _ name: String,
        start: UInt64,
        thresholdMs: Double,
        _ fields: [String: Any?] = [:]
    ) {
        let elapsed = elapsedMs(since: start)
        guard elapsed >= thresholdMs else { return }
        var output = fields
        output["ms"] = ms(elapsed)
        log(name, output)
    }

    static func ms(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func format(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "nil" }
        if let value = value as? Double {
            return ms(value)
        }
        if let value = value as? Float {
            return ms(Double(value))
        }
        if let value = value as? Bool {
            return value ? "1" : "0"
        }
        let text = String(describing: value)
        guard text.count > 220 else { return text }
        return "\(text.prefix(96))…\(text.suffix(96))"
    }
}
#endif

enum CodexAppServerPanelStatus: Equatable {
    case stopped
    case starting
    case ready
    case running
    case failed(String)

    var localizedTitle: String {
        switch self {
        case .stopped:
            return String(localized: "codexAppServer.status.stopped", defaultValue: "Stopped")
        case .starting:
            return String(localized: "codexAppServer.status.starting", defaultValue: "Starting")
        case .ready:
            return String(localized: "codexAppServer.status.ready", defaultValue: "Ready")
        case .running:
            return String(localized: "codexAppServer.status.running", defaultValue: "Running")
        case .failed:
            return String(localized: "codexAppServer.status.failed", defaultValue: "Failed")
        }
    }

    var isBusy: Bool {
        switch self {
        case .starting, .running:
            return true
        case .stopped, .ready, .failed:
            return false
        }
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

enum CodexAppServerTranscriptLoadingPhase: Equatable {
    case idle
    case startingServer
    case restoringHistory
    case resumingThread

    var isLoading: Bool {
        self != .idle
    }

    var localizedTitle: String {
        switch self {
        case .idle:
            return ""
        case .startingServer:
            return String(localized: "codexAppServer.loading.startingServer", defaultValue: "Starting Codex…")
        case .restoringHistory:
            return String(localized: "codexAppServer.loading.restoringHistory", defaultValue: "Loading conversation…")
        case .resumingThread:
            return String(localized: "codexAppServer.loading.resumingThread", defaultValue: "Resuming conversation…")
        }
    }
}

enum CodexAppServerTranscriptContentState: Equatable {
    case loading(CodexAppServerTranscriptLoadingPhase)
    case empty
    case content

    static func resolve(
        hasTranscriptItems: Bool,
        hasPendingRequests: Bool,
        status: CodexAppServerPanelStatus,
        loadingPhase: CodexAppServerTranscriptLoadingPhase
    ) -> Self {
        if hasTranscriptItems || hasPendingRequests {
            return .content
        }
        if loadingPhase.isLoading {
            return .loading(loadingPhase)
        }
        if status == .starting {
            return .loading(.startingServer)
        }
        if status == .running {
            return .loading(.resumingThread)
        }
        return .empty
    }
}

enum CodexAppServerTranscriptRole: Equatable, Sendable {
    case user
    case assistant
    case event
    case stderr
    case error
}

enum CodexAppServerTranscriptPresentation: Equatable, Sendable {
    case plain
    case lifecycleEvent
    case thinkingIndicator
    case reasoning
    case warning
    case toolCall(name: String?)
    case toolOutput
    case commandOutput
    case compaction
    case hookEvent(method: String)
}

enum CodexAppServerQuietNotificationPolicy {
    static let methodNames: Set<String> = [
        "account/updated",
        "app/list/updated",
        "fs/changed",
        "fuzzyFileSearch/sessionCompleted",
        "fuzzyFileSearch/sessionUpdated",
        "mcpServer/startupStatus/updated",
        "remoteControl/status/changed",
        "skills/changed",
        "thread/goal/cleared",
        "thread/goal/updated",
        "thread/name/updated",
        "thread/status/changed",
        "thread/tokenUsage/updated",
    ]

    static func shouldSuppressTranscript(method: String) -> Bool {
        methodNames.contains(method)
    }
}

struct CodexAppServerRateLimitWindow: Equatable, Sendable {
    var name: String
    var usedPercent: Double?
    var resetsAt: Date?
    var windowDurationMins: Int?

    var clampedUsedFraction: Double {
        guard let usedPercent else { return 0 }
        return min(1, max(0, usedPercent / 100))
    }

    var displayPercent: String {
        guard let usedPercent else { return "--" }
        return "\(Int(usedPercent.rounded()))%"
    }
}

struct CodexAppServerRateLimitSummary: Equatable, Sendable {
    var primary: CodexAppServerRateLimitWindow?
    var secondary: CodexAppServerRateLimitWindow?
    var updatedAt: Date

    init?(params: [String: Any]?, updatedAt: Date = Date()) {
        guard let rateLimits = params?["rateLimits"] as? [String: Any] else {
            return nil
        }
        primary = Self.window(named: "primary", from: rateLimits)
        secondary = Self.window(named: "secondary", from: rateLimits)
        self.updatedAt = updatedAt

        if primary == nil, secondary == nil {
            return nil
        }
    }

    var windows: [CodexAppServerRateLimitWindow] {
        [primary, secondary].compactMap { $0 }
    }

    private static func window(named name: String, from rateLimits: [String: Any]) -> CodexAppServerRateLimitWindow? {
        guard let object = rateLimits[name] as? [String: Any] else { return nil }
        return CodexAppServerRateLimitWindow(
            name: name,
            usedPercent: doubleValue(named: "usedPercent", in: object),
            resetsAt: dateValue(named: "resetsAt", in: object),
            windowDurationMins: intValue(named: "windowDurationMins", in: object)
        )
    }

    private static func doubleValue(named key: String, in object: [String: Any]) -> Double? {
        if let value = object[key] as? Double {
            return value
        }
        if let value = object[key] as? Int {
            return Double(value)
        }
        if let value = object[key] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.doubleValue
        }
        if let value = object[key] as? String {
            return Double(value)
        }
        return nil
    }

    private static func intValue(named key: String, in object: [String: Any]) -> Int? {
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.intValue
        }
        if let value = object[key] as? String {
            return Int(value)
        }
        return nil
    }

    private static func dateValue(named key: String, in object: [String: Any]) -> Date? {
        if let value = doubleValue(named: key, in: object) {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }
}

struct CodexAppServerModelInfo: Identifiable, Equatable, Sendable {
    var id: String
    var model: String
    var displayName: String
    var description: String
    var additionalSpeedTiers: [String]
    var isDefault: Bool

    init?(object: [String: Any]) {
        guard let id = Self.stringValue(named: "id", in: object),
              let model = Self.stringValue(named: "model", in: object) else {
            return nil
        }
        self.id = id
        self.model = model
        displayName = Self.stringValue(named: "displayName", in: object) ?? model
        description = Self.stringValue(named: "description", in: object) ?? ""
        additionalSpeedTiers = Self.stringArrayValue(named: "additionalSpeedTiers", in: object)
        isDefault = Self.boolValue(named: "isDefault", in: object) ?? false
    }

    var pickerTitle: String {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let humanizedModel = Self.humanizedModelName(model)
        if trimmedDisplayName.isEmpty {
            return humanizedModel
        }
        if trimmedDisplayName.count <= 8, !humanizedModel.isEmpty {
            return humanizedModel
        }
        let lowerDisplayName = trimmedDisplayName.lowercased()
        if lowerDisplayName.contains("gpt") || lowerDisplayName.contains("codex") {
            return trimmedDisplayName
        }
        if model.lowercased().contains("codex"), !humanizedModel.isEmpty {
            return humanizedModel
        }
        return trimmedDisplayName
    }

    var supportsFastMode: Bool {
        additionalSpeedTiers.contains("fast")
    }

    private static func stringValue(named key: String, in object: [String: Any]) -> String? {
        if let value = object[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func stringArrayValue(named key: String, in object: [String: Any]) -> [String] {
        guard let values = object[key] as? [Any] else { return [] }
        return values.compactMap { value in
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func boolValue(named key: String, in object: [String: Any]) -> Bool? {
        if let value = object[key] as? Bool {
            return value
        }
        if let value = object[key] as? NSNumber,
           CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value.boolValue
        }
        return nil
    }

    private static func humanizedModelName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let parts = trimmed
            .split(separator: "-")
            .map { part -> String in
                switch part.lowercased() {
                case "gpt":
                    return "GPT"
                case "codex":
                    return "Codex"
                case "spark":
                    return "Spark"
                default:
                    return String(part)
                }
            }
        guard parts.count > 1, parts[0] == "GPT" else {
            return parts.joined(separator: " ")
        }
        return (["GPT-\(parts[1])"] + parts.dropFirst(2)).joined(separator: " ")
    }
}

struct CodexAppServerContextSummary: Equatable, Sendable {
    var usedTokens: Int
    var contextWindowTokens: Int

    init?(params: [String: Any]?) {
        let usage = params?["tokenUsage"] as? [String: Any]
            ?? params?["token_usage"] as? [String: Any]
            ?? params
        guard let usage else { return nil }

        let total = usage["total"] as? [String: Any]
            ?? usage["last"] as? [String: Any]
        let usedTokens = Self.intValue(named: "totalTokens", in: total)
            ?? Self.intValue(named: "total_tokens", in: total)
            ?? Self.intValue(named: "totalTokens", in: usage)
            ?? Self.intValue(named: "total_tokens", in: usage)
        let contextWindowTokens = Self.intValue(named: "modelContextWindow", in: usage)
            ?? Self.intValue(named: "model_context_window", in: usage)

        guard let usedTokens,
              let contextWindowTokens,
              contextWindowTokens > 0 else {
            return nil
        }
        self.usedTokens = usedTokens
        self.contextWindowTokens = contextWindowTokens
    }

    var remainingPercent: Int {
        let remaining = max(0, contextWindowTokens - usedTokens)
        return Int((Double(remaining) / Double(contextWindowTokens) * 100).rounded())
    }

    private static func intValue(named key: String, in object: [String: Any]?) -> Int? {
        guard let object else { return nil }
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.intValue
        }
        if let value = object[key] as? String {
            return Int(value)
        }
        return nil
    }
}

struct CodexAppServerTranscriptItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var role: CodexAppServerTranscriptRole
    var title: String
    var body: String
    var date: Date
    var isStreaming: Bool
    var presentation: CodexAppServerTranscriptPresentation

    init(
        id: UUID = UUID(),
        role: CodexAppServerTranscriptRole,
        title: String,
        body: String,
        date: Date = Date(),
        isStreaming: Bool = false,
        presentation: CodexAppServerTranscriptPresentation = .plain
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.body = body
        self.date = date
        self.isStreaming = isStreaming
        self.presentation = presentation
    }
}

struct CodexAppServerPendingRequest: Identifiable {
    let id: CodexAppServerRequestID
    let method: String
    let params: [String: Any]?
    let summary: String

    var supportsDecisionResponse: Bool {
        approvalResponseResult(for: .decline) != nil
    }

    func approvalResponseResult(for decision: CodexAppServerApprovalDecision) -> [String: Any]? {
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            return ["decision": decision.rawValue]
        case "item/permissions/requestApproval":
            switch decision {
            case .accept:
                return [
                    "permissions": params?["permissions"] as? [String: Any] ?? [:],
                    "scope": "turn",
                ]
            case .decline, .cancel:
                return [
                    "permissions": [:],
                    "scope": "turn",
                ]
            }
        case "applyPatchApproval",
             "execCommandApproval":
            return ["decision": decision.legacyReviewDecision]
        default:
            return nil
        }
    }
}

struct CodexAppServerResumeSnapshot: Equatable {
    var threadId: String
    var cwd: String?
    var transcriptItems: [CodexAppServerTranscriptItem]
    var totalRestoredItemCount: Int
    var didTruncate: Bool
    var responseWasTruncated: Bool
}

struct CodexSessionHistorySnapshot: Equatable, Sendable {
    var threadId: String
    var fileURL: URL?
    var transcriptItems: [CodexAppServerTranscriptItem]
    var totalDisplayableItemCount: Int
    var totalDisplayableItemCountIsExact = true
    var didTruncate: Bool
}

enum CodexAppServerTranscriptPolicy {
    static let maxItemCharacters = 160_000

    static func truncatedBody(_ body: String) -> String {
        guard body.utf8.count > maxItemCharacters else { return body }
        let prefix = String(
            localized: "codexAppServer.transcriptItem.truncatedPrefix",
            defaultValue: "[Earlier output omitted]"
        )
        return "\(prefix)\n\(String(body.suffix(maxItemCharacters)))"
    }

    static func transcriptItems(fromStderr text: String, date: Date = Date()) -> [CodexAppServerTranscriptItem] {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")
        var items: [CodexAppServerTranscriptItem] = []
        var stderrBuffer = ""
        var foundWarning = false

        func appendStderrBufferIfNeeded() {
            guard !stderrBuffer.isEmpty else { return }
            items.append(stderrTranscriptItem(from: stderrBuffer, date: date))
            stderrBuffer = ""
        }

        for index in lines.indices {
            let line = lines[index]
            let hasTrailingNewline = index < lines.index(before: lines.endIndex)
            if shouldSuppressWarningTranscriptItem(fromStderrLine: line) {
                foundWarning = true
                continue
            } else if let warningItem = warningTranscriptItem(fromStderrLine: line, date: date) {
                appendStderrBufferIfNeeded()
                items.append(warningItem)
                foundWarning = true
            } else {
                stderrBuffer += line
                if hasTrailingNewline {
                    stderrBuffer += "\n"
                }
            }
        }

        guard foundWarning else {
            return text.isEmpty ? [] : [stderrTranscriptItem(from: text, date: date)]
        }

        appendStderrBufferIfNeeded()
        return items
    }

    static func normalizedWarningMessage(_ message: String) -> String {
        var lines = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.first?.caseInsensitiveCompare("Warning") == .orderedSame {
            lines.removeFirst()
        }
        if let first = lines.first,
           first.lowercased().hasPrefix("warning: ") {
            lines[0] = String(first.dropFirst("Warning: ".count))
        }
        return lines.joined(separator: "\n")
    }

    static func codexErrorDisplay(from params: [String: Any]?) -> (title: String, message: String) {
        let error = params?["error"] as? [String: Any] ?? params
        let info = stringValue(named: "codexErrorInfo", in: error)
            ?? stringValue(named: "codex_error_info", in: error)
            ?? stringValue(named: "code", in: error)
        let message = stringValue(named: "message", in: error)
            ?? stringValue(named: "message", in: params)
            ?? prettyJSON(params)

        let title: String
        switch info?.lowercased() ?? "" {
        case "usagelimitexceeded", "usage_limit_exceeded":
            title = String(localized: "codexAppServer.error.usageLimitExceeded", defaultValue: "Usage limit reached")
        case "contextwindowexceeded", "context_window_exceeded":
            title = String(localized: "codexAppServer.error.contextWindowExceeded", defaultValue: "Context window exceeded")
        case "serveroverloaded", "server_overloaded":
            title = String(localized: "codexAppServer.error.serverOverloaded", defaultValue: "Server overloaded")
        default:
            title = String(localized: "codexAppServer.error.codexError", defaultValue: "Codex error")
        }
        return (title, message)
    }

    private static func stderrTranscriptItem(from text: String, date: Date) -> CodexAppServerTranscriptItem {
        CodexAppServerTranscriptItem(
            role: .stderr,
            title: String(localized: "codexAppServer.event.stderr", defaultValue: "stderr"),
            body: truncatedBody(text),
            date: date
        )
    }

    private static func warningTranscriptItem(
        fromStderrLine line: String,
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              let data = trimmedLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let level = stringValue(named: "level", in: object)?.lowercased(),
              level == "warn" || level == "warning" else {
            return nil
        }

        let fields = object["fields"] as? [String: Any]
        let rawMessage = stringValue(named: "message", in: fields)
            ?? stringValue(named: "message", in: object)
            ?? stringValue(named: "target", in: object)
            ?? prettyJSON(object)
        let message = normalizedWarningMessage(rawMessage)
        guard !message.isEmpty else { return nil }

        return CodexAppServerTranscriptItem(
            role: .event,
            title: String(localized: "codexAppServer.event.warning", defaultValue: "Warning"),
            body: truncatedBody(message),
            date: date,
            presentation: .warning
        )
    }

    private static func shouldSuppressWarningTranscriptItem(fromStderrLine line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              let data = trimmedLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let level = stringValue(named: "level", in: object)?.lowercased(),
              level == "warn" || level == "warning" else {
            return false
        }

        let fields = object["fields"] as? [String: Any]
        let message = stringValue(named: "message", in: fields)
            ?? stringValue(named: "message", in: object)
            ?? ""
        let target = stringValue(named: "target", in: object) ?? ""
        guard target == "codex_rollout::list" || target == "codex_rollout::state_db" else {
            return false
        }
        return message.contains("state db discrepancy during find_thread_path_by_id_str_in_subdir")
            || message.contains("state db discrepancy during read_repair_rollout_path")
    }

    private static func stringValue(named key: String, in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let value = object[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = object[key] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func prettyJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}

enum CodexAppServerApprovalDecision: String {
    case accept
    case decline
    case cancel

    var legacyReviewDecision: String {
        switch self {
        case .accept:
            return "approved"
        case .decline:
            return "denied"
        case .cancel:
            return "abort"
        }
    }
}

enum CodexAppServerPromptQueueKind: Equatable, Sendable {
    case steer
    case followUp

    var localizedLabel: String {
        switch self {
        case .steer:
            return String(localized: "codexAppServer.queue.steer", defaultValue: "Steering")
        case .followUp:
            return String(localized: "codexAppServer.queue.followUp", defaultValue: "Queued")
        }
    }

    var localizedShortLabel: String {
        switch self {
        case .steer:
            return String(localized: "codexAppServer.queue.steer.short", defaultValue: "Steer")
        case .followUp:
            return String(localized: "codexAppServer.queue.followUp.short", defaultValue: "Next")
        }
    }
}

struct CodexAppServerQueuedPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var kind: CodexAppServerPromptQueueKind
    var date: Date

    init(id: UUID = UUID(), text: String, kind: CodexAppServerPromptQueueKind, date: Date = Date()) {
        self.id = id
        self.text = text
        self.kind = kind
        self.date = date
    }
}

struct CodexPromptSelectionRange: Equatable, Sendable {
    var location: Int
    var length: Int

    init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    init(_ range: NSRange) {
        let rangeLocation = range.location == NSNotFound ? 0 : range.location
        let rangeLength = range.length == NSNotFound ? 0 : range.length
        self.init(location: rangeLocation, length: rangeLength)
    }

    static func caret(at location: Int) -> Self {
        Self(location: location, length: 0)
    }

    func clamped(to textLength: Int) -> Self {
        let safeTextLength = max(0, textLength)
        let safeLocation = min(max(0, location), safeTextLength)
        let safeLength = min(max(0, length), max(0, safeTextLength - safeLocation))
        return Self(location: safeLocation, length: safeLength)
    }

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }

    static func normalized(
        _ ranges: [CodexPromptSelectionRange],
        textLength: Int,
        fallbackToEnd: Bool = true
    ) -> [CodexPromptSelectionRange] {
        guard !ranges.isEmpty else {
            return [.caret(at: fallbackToEnd ? max(0, textLength) : 0)]
        }
        return ranges.map { $0.clamped(to: textLength) }
    }

    static func normalized(
        nsRanges: [NSValue],
        textLength: Int,
        fallbackToEnd: Bool = true
    ) -> [CodexPromptSelectionRange] {
        normalized(
            nsRanges.map { CodexPromptSelectionRange($0.rangeValue) },
            textLength: textLength,
            fallbackToEnd: fallbackToEnd
        )
    }

    static func nsValues(
        from ranges: [CodexPromptSelectionRange],
        textLength: Int,
        fallbackToEnd: Bool = true
    ) -> [NSValue] {
        normalized(ranges, textLength: textLength, fallbackToEnd: fallbackToEnd)
            .map { NSValue(range: $0.nsRange) }
    }
}

struct CodexAppServerStderrTranscriptBuffer {
    private var pendingText = ""

    mutating func append(_ text: String, date: Date = Date()) -> [CodexAppServerTranscriptItem] {
        guard !text.isEmpty else { return [] }
        pendingText += text
        let holdsTrailingCarriageReturn = pendingText.hasSuffix("\r")
        let textToNormalize = holdsTrailingCarriageReturn
            ? String(pendingText.dropLast())
            : pendingText
        pendingText = textToNormalize
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if holdsTrailingCarriageReturn {
            pendingText += "\r"
        }

        guard let lastNewlineIndex = pendingText.lastIndex(of: "\n") else {
            return []
        }

        let completeEndIndex = pendingText.index(after: lastNewlineIndex)
        let completeText = String(pendingText[..<completeEndIndex])
        pendingText = String(pendingText[completeEndIndex...])
        return CodexAppServerTranscriptPolicy.transcriptItems(fromStderr: completeText, date: date)
    }

    mutating func flush(date: Date = Date()) -> [CodexAppServerTranscriptItem] {
        guard !pendingText.isEmpty else { return [] }
        let text = pendingText
        pendingText.removeAll(keepingCapacity: false)
        return CodexAppServerTranscriptPolicy.transcriptItems(fromStderr: text, date: date)
    }

    mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
        pendingText.removeAll(keepingCapacity: keepCapacity)
    }
}

@MainActor
final class CodexAppServerPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .codexAppServer

    private static let restoredTranscriptItemLimit = 250
    private static let localHistoryItemLimit = 2_000
    private static let maxTranscriptItems = 2_500
    private static let requestedReasoningSummary = "detailed"
    private static let anonymousReasoningItemKey = "__cmux_anonymous_reasoning"

    private(set) var workspaceId: UUID

    @Published var promptText: String = ""
    @Published var cwd: String
    @Published private(set) var status: CodexAppServerPanelStatus = .stopped
    @Published private(set) var transcriptItems: [CodexAppServerTranscriptItem] = []
    @Published private(set) var pendingRequests: [CodexAppServerPendingRequest] = []
    @Published private(set) var transcriptLoadingPhase: CodexAppServerTranscriptLoadingPhase = .idle
    @Published private(set) var rateLimitSummary: CodexAppServerRateLimitSummary?
    @Published private(set) var contextSummary: CodexAppServerContextSummary?
    @Published private(set) var availableModels: [CodexAppServerModelInfo] = []
    @Published private(set) var isModelListLoading = false
    @Published var selectedModelId: String?
    @Published var fastModeEnabled: Bool = false
    @Published private(set) var pendingSteers: [CodexAppServerQueuedPrompt] = []
    @Published private(set) var queuedFollowUps: [CodexAppServerQueuedPrompt] = []
    var promptSelectionRanges: [CodexPromptSelectionRange] = [.caret(at: 0)]
    let provider: AgentSessionProvider

    private let client: any CodexAppServerClienting
    private let initialResumeThreadId: String?
    private let autoStartOnAppear: Bool
    private var threadId: String?
    private var currentTurnId: String?
    private var activeAssistantItemId: UUID?
    private var activeReasoningItemIDs: [String: UUID] = [:]
    private var activeCommandOutputItemIDs: [String: UUID] = [:]
    private var anonymousCommandOutputItemID: UUID?
    private var lastRenderedUserMessageText: String?
    private var initialResumeThreadUnavailable = false
    private var isStarted = false
    private var isClosed = false
    private var didResumeInitialThread = false
    private var isStartingNewTurn = false
    private var startupUserItemsToPreserve: [CodexAppServerTranscriptItem] = []
    private var lifecycleGeneration = 0
    private var initialHistoryRestoreThreadId: String?
    private var initialHistoryRestoreTask: Task<CodexSessionHistorySnapshot, Never>?
    private var stderrTranscriptBuffer = CodexAppServerStderrTranscriptBuffer()

    var displayTitle: String {
        if status.isFailed {
            return String(
                format: String(localized: "agentSession.panel.title.failed.format", defaultValue: "%@ Error"),
                provider.displayName
            )
        }
        return provider.displayName
    }

    var displayIcon: String? {
        if status.isFailed {
            return "exclamationmark.triangle.fill"
        }
        return "sparkles"
    }

    var isDirty: Bool {
        status.isFailed
    }

    var canSendPrompt: Bool {
        !status.isFailed && !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var queuedPrompts: [CodexAppServerQueuedPrompt] {
        pendingSteers + queuedFollowUps
    }

    var canInterruptPendingPrompts: Bool {
        status.isBusy && !pendingSteers.isEmpty && threadId != nil && hasActiveTurn
    }

    var shouldAutoStart: Bool {
        autoStartOnAppear
    }

    private var hasActiveTurn: Bool {
        guard let currentTurnId = currentTurnId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !currentTurnId.isEmpty
    }

    var selectedModel: CodexAppServerModelInfo? {
        if let selectedModelId,
           let model = availableModels.first(where: { $0.id == selectedModelId || $0.model == selectedModelId }) {
            return model
        }
        return availableModels.first(where: \.isDefault) ?? availableModels.first
    }

    var selectedModelDisplayName: String {
        selectedModel?.pickerTitle
            ?? provider.displayName
    }

    var selectedModelParameter: String? {
        selectedModel?.model
    }

    var effectiveServiceTier: String? {
        guard fastModeEnabled,
              selectedModel?.supportsFastMode == true else {
            return nil
        }
        return "fast"
    }

    func updatePromptSelectionRanges(_ ranges: [CodexPromptSelectionRange]) {
        let textLength = (promptText as NSString).length
        promptSelectionRanges = CodexPromptSelectionRange.normalized(ranges, textLength: textLength)
    }

    func selectModel(_ modelId: String) {
        selectedModelId = modelId
        if selectedModel?.supportsFastMode != true {
            fastModeEnabled = false
        }
    }

    func setFastModeEnabled(_ enabled: Bool) {
        fastModeEnabled = enabled && selectedModel?.supportsFastMode == true
    }

    var transcriptContentState: CodexAppServerTranscriptContentState {
        CodexAppServerTranscriptContentState.resolve(
            hasTranscriptItems: !transcriptItems.isEmpty,
            hasPendingRequests: !pendingRequests.isEmpty,
            status: status,
            loadingPhase: transcriptLoadingPhase
        )
    }

    var resumableThreadId: String? {
        if let current = normalizedThreadId(threadId) {
            return current
        }
        if initialResumeThreadUnavailable {
            return nil
        }
        return normalizedThreadId(initialResumeThreadId)
    }

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        cwd: String,
        resumeThreadId: String? = nil,
        autoStartOnAppear: Bool = true,
        provider: AgentSessionProvider = .provider(.codex),
        client: (any CodexAppServerClienting)? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.provider = provider
        self.initialResumeThreadId = Self.normalizedCodexThreadId(resumeThreadId)
        self.autoStartOnAppear = autoStartOnAppear
        self.client = client ?? CodexAppServerClient(provider: provider)
    }

    deinit {
        client.onEvent = nil
        client.stop()
    }

    func start() async {
        guard !isStarted, status != .starting else { return }
#if DEBUG
        let startTime = CodexAppServerTiming.now()
#endif
        let generation = lifecycleGeneration
        installClientEventHandler(generation: generation)
        let currentResumeThreadId = normalizedThreadId(threadId)
        let initialResumeCandidate = initialResumeThreadUnavailable
            ? nil
            : normalizedThreadId(initialResumeThreadId)
        let pendingResumeThreadId = currentResumeThreadId ?? initialResumeCandidate
        let isResumingInitialThread = pendingResumeThreadId == initialResumeCandidate
        let shouldResumePendingThread = pendingResumeThreadId != nil
            && (currentResumeThreadId != nil || !didResumeInitialThread)
#if DEBUG
        CodexAppServerTiming.log("panel.start.begin", [
            "panel": id.uuidString.prefix(8),
            "workspace": workspaceId.uuidString.prefix(8),
            "has_resume": shouldResumePendingThread,
            "cwd": currentWorkingDirectory(),
        ])
#endif
        status = .starting
        stderrTranscriptBuffer.removeAll(keepingCapacity: true)
        transcriptLoadingPhase = shouldResumePendingThread
            ? .restoringHistory
            : .startingServer
        if let pendingResumeThreadId,
           shouldResumePendingThread {
            threadId = pendingResumeThreadId
            startInitialHistoryRestore(threadId: pendingResumeThreadId, generation: generation)
        }
        do {
#if DEBUG
            let initializeStart = CodexAppServerTiming.now()
#endif
            try await client.startAndInitialize()
#if DEBUG
            CodexAppServerTiming.log("panel.clientInitialized", [
                "panel": id.uuidString.prefix(8),
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: initializeStart)),
            ])
#endif
            guard isCurrentLifecycle(generation) else {
                client.stop()
                return
            }
            isStarted = true
            Task { @MainActor [weak self] in
                await self?.refreshCodexMetadata(generation: generation)
            }
            if let pendingResumeThreadId,
               shouldResumePendingThread {
                status = .running
                if transcriptItems.isEmpty {
                    transcriptLoadingPhase = .resumingThread
                }
#if DEBUG
                let resumeStart = CodexAppServerTiming.now()
                CodexAppServerTiming.log("panel.resume.begin", [
                    "panel": id.uuidString.prefix(8),
                    "thread": pendingResumeThreadId,
                    "items_before": transcriptItems.count,
                ])
#endif
                let renderedUserItemsToPreserve = isStartingNewTurn ? startupUserItemsToPreserve : []
                let response: [String: Any]
                do {
                    response = try await client.resumeThread(
                        threadId: pendingResumeThreadId,
                        cwd: currentWorkingDirectory()
                    )
                } catch {
                    guard Self.isMissingRolloutResumeError(error) else {
                        throw error
                    }
#if DEBUG
                    CodexAppServerTiming.log("panel.resume.missingRolloutFallback", [
                        "panel": id.uuidString.prefix(8),
                        "thread": pendingResumeThreadId,
                        "error": error.localizedDescription,
                    ])
#endif
                    guard isCurrentLifecycle(generation) else {
                        client.stop()
                        return
                    }
                    initialHistoryRestoreTask?.cancel()
                    initialHistoryRestoreTask = nil
                    initialHistoryRestoreThreadId = nil
                    if isResumingInitialThread {
                        initialResumeThreadUnavailable = true
                        didResumeInitialThread = true
                    }
                    threadId = nil
                    currentTurnId = nil
                    transcriptItems = renderedUserItemsToPreserve
                    pendingRequests.removeAll()
                    contextSummary = nil
                    status = .ready
                    transcriptLoadingPhase = .idle
                    drainNextQueuedFollowUpIfNeeded()
                    return
                }
#if DEBUG
                CodexAppServerTiming.log("panel.resume.response", [
                    "panel": id.uuidString.prefix(8),
                    "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: resumeStart)),
                    "keys": response.keys.sorted().joined(separator: ","),
                    "truncated": (response["_cmuxResponseTruncated"] as? Bool) == true,
                ])
#endif
                guard isCurrentLifecycle(generation) else {
                    client.stop()
                    return
                }
                if isResumingInitialThread {
                    didResumeInitialThread = true
                }
#if DEBUG
                let applyStart = CodexAppServerTiming.now()
#endif
                let snapshot = applyResumeResponse(response, fallbackThreadId: pendingResumeThreadId)
#if DEBUG
                CodexAppServerTiming.log("panel.resume.applied", [
                    "panel": id.uuidString.prefix(8),
                    "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: applyStart)),
                    "snapshot_items": snapshot.transcriptItems.count,
                    "snapshot_total": snapshot.totalRestoredItemCount,
                    "did_truncate": snapshot.didTruncate,
                    "response_truncated": snapshot.responseWasTruncated,
                    "transcript_items": transcriptItems.count,
                ])
#endif
                if snapshot.responseWasTruncated {
                    transcriptLoadingPhase = .restoringHistory
                    await loadLocalHistory(for: snapshot.threadId, generation: generation)
                }
                preserveRenderedUserItemsAfterResume(renderedUserItemsToPreserve)
                guard isCurrentLifecycle(generation) else {
                    client.stop()
                    return
                }
                status = .ready
                transcriptLoadingPhase = .idle
                drainNextQueuedFollowUpIfNeeded()
            } else {
                status = .ready
                transcriptLoadingPhase = .idle
                drainNextQueuedFollowUpIfNeeded()
            }
#if DEBUG
            CodexAppServerTiming.log("panel.start.end", [
                "panel": id.uuidString.prefix(8),
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: startTime)),
                "status": String(describing: status),
                "items": transcriptItems.count,
            ])
#endif
        } catch {
            guard isCurrentLifecycle(generation) else { return }
            lifecycleGeneration += 1
            initialHistoryRestoreTask?.cancel()
            initialHistoryRestoreTask = nil
            initialHistoryRestoreThreadId = nil
            client.onEvent = nil
            client.stop()
            isStarted = false
            transcriptLoadingPhase = .idle
            status = .failed(error.localizedDescription)
            appendError(error.localizedDescription)
#if DEBUG
            CodexAppServerTiming.log("panel.start.error", [
                "panel": id.uuidString.prefix(8),
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: startTime)),
                "error": error.localizedDescription,
            ])
#endif
        }
    }

    nonisolated static func isMissingRolloutResumeError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("no rollout found for thread id")
            || message.contains("no rollout found")
    }

    private func refreshCodexMetadata(generation: Int) async {
        guard isCurrentLifecycle(generation), isStarted else { return }
        isModelListLoading = true
        do {
            let models = try await client.listModels(includeHidden: true)
                .compactMap(CodexAppServerModelInfo.init(object:))
                .filter { !$0.pickerTitle.isEmpty }
            guard isCurrentLifecycle(generation) else {
                return
            }
            availableModels = models
            if selectedModelId == nil || selectedModel == nil {
                selectedModelId = models.first(where: \.isDefault)?.id ?? models.first?.id
            }
            if selectedModel?.supportsFastMode != true {
                fastModeEnabled = false
            }
        } catch {
#if DEBUG
            CodexAppServerTiming.log("panel.modelList.error", [
                "panel": id.uuidString.prefix(8),
                "error": error.localizedDescription,
            ])
#endif
        }
        if isCurrentLifecycle(generation) {
            isModelListLoading = false
        }

        do {
            let rateLimits = try await client.readRateLimits()
            guard isCurrentLifecycle(generation) else { return }
            rateLimitSummary = CodexAppServerRateLimitSummary(params: rateLimits)
        } catch {
#if DEBUG
            CodexAppServerTiming.log("panel.rateLimits.error", [
                "panel": id.uuidString.prefix(8),
                "error": error.localizedDescription,
            ])
#endif
        }
    }

    func stop() {
        lifecycleGeneration += 1
        initialHistoryRestoreTask?.cancel()
        initialHistoryRestoreTask = nil
        initialHistoryRestoreThreadId = nil
        client.onEvent = nil
        client.stop()
        stderrTranscriptBuffer.removeAll(keepingCapacity: true)
        isStarted = false
        isModelListLoading = false
        threadId = nil
        currentTurnId = nil
        activeAssistantItemId = nil
        activeReasoningItemIDs.removeAll(keepingCapacity: false)
        activeCommandOutputItemIDs.removeAll(keepingCapacity: false)
        anonymousCommandOutputItemID = nil
        lastRenderedUserMessageText = nil
        didResumeInitialThread = false
        isStartingNewTurn = false
        startupUserItemsToPreserve.removeAll(keepingCapacity: false)
        pendingRequests.removeAll()
        pendingSteers.removeAll()
        queuedFollowUps.removeAll()
        contextSummary = nil
        transcriptLoadingPhase = .idle
        status = .stopped
    }

    func sendPrompt() async {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !status.isFailed else { return }
        promptText = ""

        if status == .starting {
            queuedFollowUps.append(CodexAppServerQueuedPrompt(text: text, kind: .followUp))
            return
        }

        if status.isBusy {
            if !hasActiveTurn {
                queuedFollowUps.append(CodexAppServerQueuedPrompt(text: text, kind: .followUp))
                return
            }
            await submitSteer(text)
            return
        }

        await submitNewTurn(text, renderUserImmediately: true)
    }

    func queuePromptForNextTurn() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !status.isFailed else { return }
        promptText = ""
        queuedFollowUps.append(CodexAppServerQueuedPrompt(text: text, kind: .followUp))
        drainNextQueuedFollowUpIfNeeded()
    }

    func removeQueuedPrompt(id: UUID) {
        pendingSteers.removeAll { $0.id == id }
        queuedFollowUps.removeAll { $0.id == id }
    }

    func moveQueuedPrompt(id: UUID, before targetID: UUID) {
        _ = moveQueuedPrompt(in: &queuedFollowUps, id: id, before: targetID)
    }

    func setQueuedPromptKind(id: UUID, kind: CodexAppServerPromptQueueKind) {
        if let index = pendingSteers.firstIndex(where: { $0.id == id }) {
            guard kind == .steer else { return }
            pendingSteers[index].kind = .steer
            return
        }

        if let index = queuedFollowUps.firstIndex(where: { $0.id == id }) {
            var prompt = queuedFollowUps.remove(at: index)
            prompt.kind = kind
            switch kind {
            case .steer:
                guard status.isBusy, hasActiveTurn else {
                    prompt.kind = .followUp
                    queuedFollowUps.insert(prompt, at: min(index, queuedFollowUps.count))
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.submitSteer(prompt)
                }
            case .followUp:
                queuedFollowUps.insert(prompt, at: min(index, queuedFollowUps.count))
            }
        }
    }

    private func moveQueuedPrompt(
        in prompts: inout [CodexAppServerQueuedPrompt],
        id: UUID,
        before targetID: UUID
    ) -> Bool {
        guard let sourceIndex = prompts.firstIndex(where: { $0.id == id }),
              let targetIndex = prompts.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        guard sourceIndex != targetIndex else { return true }
        let prompt = prompts.remove(at: sourceIndex)
        let adjustedTargetIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        prompts.insert(prompt, at: min(adjustedTargetIndex, prompts.count))
        return true
    }

    func interruptForPendingPrompts() async {
        guard status.isBusy,
              pendingSteers.isEmpty == false,
              let threadId,
              let currentTurnId else { return }

        let steers = pendingSteers
        do {
            try await client.interruptTurn(threadId: threadId, turnId: currentTurnId)
            self.currentTurnId = nil
            status = .ready
            let merged = steers.map(\.text).joined(separator: "\n\n")
            pendingSteers.removeAll()
            if !merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await submitNewTurn(merged, renderUserImmediately: true)
            } else {
                drainNextQueuedFollowUpIfNeeded()
            }
        } catch {
            appendError(error.localizedDescription)
        }
    }

    private func submitNewTurn(_ text: String, renderUserImmediately: Bool) async {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        let generation = lifecycleGeneration
        isStartingNewTurn = true
        defer {
            if lifecycleGeneration == generation {
                isStartingNewTurn = false
                startupUserItemsToPreserve.removeAll(keepingCapacity: false)
            }
        }
        if renderUserImmediately {
            let renderedUserItem = appendUser(cleanedText)
            if !isStarted, let renderedUserItem {
                startupUserItemsToPreserve = [renderedUserItem]
            }
        }

        do {
            status = .running
            if !isStarted {
                await start()
            }
            guard isCurrentLifecycle(generation) else { return }
            guard isStarted else { return }
            status = .running
            let resolvedThreadId: String
            if let threadId {
                resolvedThreadId = threadId
            } else {
                let newThreadId = try await client.startThread(
                    cwd: currentWorkingDirectory(),
                    model: selectedModelParameter,
                    serviceTier: effectiveServiceTier
                )
                guard isCurrentLifecycle(generation) else { return }
                threadId = newThreadId
                resolvedThreadId = newThreadId
            }

            let turnId = try await client.startTurn(
                threadId: resolvedThreadId,
                text: cleanedText,
                cwd: currentWorkingDirectory(),
                model: selectedModelParameter,
                serviceTier: effectiveServiceTier,
                reasoningSummary: Self.requestedReasoningSummary
            )
            guard isCurrentLifecycle(generation) else { return }
            currentTurnId = turnId
        } catch {
            guard isCurrentLifecycle(generation) else { return }
            status = .failed(error.localizedDescription)
            appendError(error.localizedDescription)
        }
    }

    private func submitSteer(_ text: String) async {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        await submitSteer(CodexAppServerQueuedPrompt(text: cleanedText, kind: .steer))
    }

    private func submitSteer(_ queuedPrompt: CodexAppServerQueuedPrompt) async {
        let cleanedText = queuedPrompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        let generation = lifecycleGeneration
        var pending = queuedPrompt
        pending.text = cleanedText
        pending.kind = .steer
        pendingSteers.append(pending)

        do {
            let resolvedThreadId: String
            if let threadId {
                resolvedThreadId = threadId
            } else {
                resolvedThreadId = try await client.startThread(
                    cwd: currentWorkingDirectory(),
                    model: selectedModelParameter,
                    serviceTier: effectiveServiceTier
                )
                guard isCurrentLifecycle(generation) else { return }
                threadId = resolvedThreadId
            }

            if let activeTurnId = currentTurnId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !activeTurnId.isEmpty {
                let returnedTurnId = try await client.steerTurn(
                    threadId: resolvedThreadId,
                    turnId: activeTurnId,
                    text: cleanedText
                )
                guard isCurrentLifecycle(generation) else { return }
                currentTurnId = returnedTurnId
            } else {
                let returnedTurnId = try await client.startTurn(
                    threadId: resolvedThreadId,
                    text: cleanedText,
                    cwd: currentWorkingDirectory(),
                    model: selectedModelParameter,
                    serviceTier: effectiveServiceTier,
                    reasoningSummary: Self.requestedReasoningSummary
                )
                guard isCurrentLifecycle(generation) else { return }
                currentTurnId = returnedTurnId
            }
        } catch {
            guard isCurrentLifecycle(generation) else { return }
            pendingSteers.removeAll { $0.id == pending.id }
            queuedFollowUps.insert(
                CodexAppServerQueuedPrompt(id: pending.id, text: cleanedText, kind: .followUp, date: pending.date),
                at: 0
            )
            appendError(error.localizedDescription)
        }
    }

    private func drainNextQueuedFollowUpIfNeeded() {
        guard !isStartingNewTurn, !status.isBusy, !queuedFollowUps.isEmpty else { return }
        let next = queuedFollowUps.removeFirst()
        isStartingNewTurn = true
        Task { @MainActor in
            await submitNewTurn(next.text, renderUserImmediately: true)
        }
    }

    func resolvePendingRequest(_ request: CodexAppServerPendingRequest, decision: CodexAppServerApprovalDecision) {
        do {
            guard let result = request.approvalResponseResult(for: decision) else {
                try client.rejectServerRequest(
                    id: request.id,
                    message: String(
                        localized: "codexAppServer.request.unsupported",
                        defaultValue: "cmux does not support this Codex app-server request yet."
                    )
                )
                removePendingRequest(id: request.id)
                return
            }

            try client.respondToServerRequest(id: request.id, result: result)
            removePendingRequest(id: request.id)
            appendEvent(
                title: String(localized: "codexAppServer.event.approvalSent", defaultValue: "Approval response sent"),
                body: request.method
            )
        } catch {
            appendError(error.localizedDescription)
        }
    }

    func close() {
        isClosed = true
        lifecycleGeneration += 1
        initialHistoryRestoreTask?.cancel()
        initialHistoryRestoreTask = nil
        initialHistoryRestoreThreadId = nil
        stop()
    }

    func focus() {}

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    func reattachToWorkspace(_ workspaceId: UUID, cwd: String?) {
        self.workspaceId = workspaceId
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            self.cwd = cwd
        }
    }

    private func isCurrentLifecycle(_ generation: Int) -> Bool {
        !isClosed && lifecycleGeneration == generation
    }

    private func installClientEventHandler(generation: Int) {
        client.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event, generation: generation)
            }
        }
    }

    private func handle(_ event: CodexAppServerEvent, generation: Int) {
        guard isCurrentLifecycle(generation) else { return }
        switch event {
        case .notification(let notification):
            handleNotification(notification)
        case .serverRequest(let request):
            pendingRequests.append(
                CodexAppServerPendingRequest(
                    id: request.id,
                    method: request.rawMethod,
                    params: request.paramsObject,
                    summary: Self.prettyJSON(request.paramsObject)
                )
            )
            appendEvent(
                title: String(localized: "codexAppServer.event.request", defaultValue: "Approval requested"),
                body: request.rawMethod
            )
        case .stderr(let text):
            appendStderr(text)
        case .terminated(let statusCode):
            flushPendingStderr()
            isStarted = false
            currentTurnId = nil
            activeAssistantItemId = nil
            activeReasoningItemIDs.removeAll(keepingCapacity: false)
            activeCommandOutputItemIDs.removeAll(keepingCapacity: false)
            anonymousCommandOutputItemID = nil
            lastRenderedUserMessageText = nil
            pendingRequests.removeAll()
            pendingSteers.removeAll()
            queuedFollowUps.removeAll()
            transcriptLoadingPhase = .idle
            guard statusCode != 0 else {
                status = .stopped
                return
            }
            status = .failed(
                String(
                    format: String(
                        localized: "codexAppServer.error.terminatedUnexpectedly",
                        defaultValue: "Codex app-server exited unexpectedly with status %1$ld."
                    ),
                    locale: Locale.current,
                    Int(statusCode)
                )
            )
            appendEvent(
                title: String(localized: "codexAppServer.event.terminated", defaultValue: "App server exited"),
                body: String(statusCode)
            )
        }
    }

    private func handleNotification(_ notification: CodexAppServerServerNotification) {
        let method = notification.rawMethod
        let params = notification.paramsObject

        switch method {
        case "thread/started":
            if let thread = params?["thread"] as? [String: Any],
               let threadId = thread["id"] as? String {
                self.threadId = threadId
            }
        case "turn/started":
            status = .running
            if let turn = params?["turn"] as? [String: Any],
               let turnId = Self.stringValue(named: "id", in: turn),
               !turnId.isEmpty {
                currentTurnId = turnId
            }
        case "turn/completed":
            status = .ready
            currentTurnId = nil
            finishStreamingReasoningSummaries()
            finishStreamingAssistant()
            drainNextQueuedFollowUpIfNeeded()
        case "item/started":
            if handleUserMessageItem(params?["item"] as? [String: Any]) {
                break
            }
        case "item/agentMessage/delta":
            appendAssistantDelta(Self.stringValue(named: "delta", in: params))
        case "item/commandExecution/outputDelta":
            appendCommandDelta(
                Self.stringValue(named: "delta", in: params),
                itemId: Self.stringValue(named: "itemId", in: params)
                    ?? Self.stringValue(named: "id", in: params)
            )
        case "item/commandExecution/stderrDelta":
            appendCommandDelta(
                Self.stringValue(named: "delta", in: params),
                itemId: Self.stringValue(named: "itemId", in: params)
                    ?? Self.stringValue(named: "id", in: params)
            )
        case "item/reasoning/summaryTextDelta":
            appendReasoningSummaryDelta(
                Self.stringValue(named: "delta", in: params),
                itemId: Self.stringValue(named: "itemId", in: params)
                    ?? Self.stringValue(named: "id", in: params)
            )
        case "item/reasoning/summaryPartAdded":
            appendReasoningSummaryPartBreak(
                itemId: Self.stringValue(named: "itemId", in: params)
                    ?? Self.stringValue(named: "id", in: params)
            )
        case "item/reasoning/textDelta":
            break
        case "serverRequest/resolved":
            removeResolvedServerRequest(params)
        case "item/completed":
            if handleUserMessageItem(params?["item"] as? [String: Any]) {
                break
            }
            handleCompletedItem(params?["item"] as? [String: Any])
        case "userMessage":
            _ = handleUserMessageItem(params)
        case "thread/compacted":
            appendCompactionEvent()
        case "account/rateLimits/updated":
            rateLimitSummary = CodexAppServerRateLimitSummary(params: params)
        case "thread/tokenUsage/updated":
            contextSummary = CodexAppServerContextSummary(params: params)
        case "hook/started", "hook/completed":
            appendHookEvent(method: method, params: params)
        case "error":
            appendCodexErrorEvent(params)
        case "warning", "configWarning", "guardianWarning", "deprecationNotice", "windows/worldWritableWarning":
            appendEvent(
                title: String(localized: "codexAppServer.event.warning", defaultValue: "Warning"),
                body: CodexAppServerTranscriptPolicy.normalizedWarningMessage(
                    Self.stringValue(named: "message", in: params) ?? Self.prettyJSON(params)
                ),
                presentation: .warning
            )
        case let quietMethod where CodexAppServerQuietNotificationPolicy
            .shouldSuppressTranscript(method: quietMethod):
            break
        default:
            appendEvent(title: method, body: Self.prettyJSON(params))
        }
    }

    @discardableResult
    private func handleUserMessageItem(_ item: [String: Any]?) -> Bool {
        guard let item else { return false }
        let type = item["type"] as? String ?? item["kind"] as? String ?? ""
        guard type == "userMessage" else { return false }
        guard let text = Self.userMessageText(from: item) else { return true }
        commitServerUserMessage(text)
        return true
    }

    private func commitServerUserMessage(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let pendingSteerIndex = pendingSteers.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }) {
            pendingSteers.remove(at: pendingSteerIndex)
            appendUser(normalized)
            return
        }

        if lastRenderedUserMessageText?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized {
            return
        }

        appendUser(normalized)
    }

    private func handleCompletedItem(_ item: [String: Any]?) {
        guard let item else { return }
        let type = item["type"] as? String ?? item["kind"] as? String ?? ""
        switch type {
        case "agentMessage":
            let text = Self.stringValue(named: "text", in: item)
                ?? Self.stringValue(named: "message", in: item)
                ?? Self.stringValue(named: "content", in: item)
            if let text, !text.isEmpty {
                if activeAssistantItemId == nil || transcriptItems.last?.role != .assistant {
                    appendAssistantDelta(text)
                }
                finishStreamingAssistant()
            }
        case "commandExecution":
            finishCommandOutput(for: Self.itemIdentifier(from: item))
            appendEvent(
                title: String(localized: "codexAppServer.event.command", defaultValue: "Command"),
                body: Self.commandSummary(from: item),
                presentation: .toolCall(name: "shell")
            )
        case "fileChange":
            appendEvent(
                title: String(localized: "codexAppServer.event.fileChange", defaultValue: "File change"),
                body: Self.prettyJSON(item),
                presentation: .toolCall(name: "apply_patch")
            )
        case "reasoning":
            finishReasoningSummary(
                for: Self.itemIdentifier(from: item),
                summary: Self.reasoningSummaryText(from: item)
            )
        case "error":
            appendCodexErrorEvent(item)
        default:
            appendEvent(title: type.isEmpty ? "item/completed" : type, body: Self.prettyJSON(item))
        }
    }

    @discardableResult
    private func appendUser(_ text: String) -> CodexAppServerTranscriptItem? {
        lastRenderedUserMessageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return append(
            role: .user,
            title: String(localized: "codexAppServer.role.user", defaultValue: "You"),
            body: text
        )
    }

    private func appendAssistantDelta(_ delta: String?) {
        guard let delta, !delta.isEmpty else { return }
        if let id = activeAssistantItemId,
           let index = transcriptItems.firstIndex(where: { $0.id == id }) {
            transcriptItems[index].body = Self.truncatedTranscriptBody(transcriptItems[index].body + delta)
            transcriptItems[index].date = Date()
        } else {
            let item = CodexAppServerTranscriptItem(
                role: .assistant,
                title: String(localized: "codexAppServer.role.assistant", defaultValue: "Codex"),
                body: Self.truncatedTranscriptBody(delta),
                isStreaming: true
            )
            activeAssistantItemId = item.id
            transcriptItems.append(item)
            trimTranscriptItemsIfNeeded()
        }
    }

    private func appendReasoningSummaryDelta(_ delta: String?, itemId: String?) {
        guard let delta, !delta.isEmpty else { return }
        let itemKey = normalizedReasoningItemKey(itemId)
        if let id = activeReasoningItemIDs[itemKey],
           let index = transcriptItems.firstIndex(where: { $0.id == id }) {
            transcriptItems[index].body = Self.truncatedTranscriptBody(transcriptItems[index].body + delta)
            transcriptItems[index].date = Date()
            return
        }

        let item = CodexAppServerTranscriptItem(
            role: .event,
            title: String(localized: "codexAppServer.event.reasoning", defaultValue: "Reasoning"),
            body: Self.truncatedTranscriptBody(delta),
            isStreaming: true,
            presentation: .reasoning
        )
        activeReasoningItemIDs[itemKey] = item.id
        transcriptItems.append(item)
        trimTranscriptItemsIfNeeded()
    }

    private func appendReasoningSummaryPartBreak(itemId: String?) {
        let itemKey = normalizedReasoningItemKey(itemId)
        guard let id = activeReasoningItemIDs[itemKey],
              let index = transcriptItems.firstIndex(where: { $0.id == id }) else {
            return
        }
        let currentBody = transcriptItems[index].body
        guard !currentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !currentBody.hasSuffix("\n\n") else {
            return
        }
        transcriptItems[index].body = Self.truncatedTranscriptBody(currentBody + "\n\n")
        transcriptItems[index].date = Date()
    }

    private func finishReasoningSummary(for itemId: String?, summary: String?) {
        let itemKey = normalizedReasoningItemKey(itemId)
        let body = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = activeReasoningItemIDs.removeValue(forKey: itemKey),
           let index = transcriptItems.firstIndex(where: { $0.id == id }) {
            if let body, !body.isEmpty {
                transcriptItems[index].body = Self.truncatedTranscriptBody(body)
            }
            if transcriptItems[index].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcriptItems.remove(at: index)
            } else {
                transcriptItems[index].isStreaming = false
                transcriptItems[index].date = Date()
            }
            return
        }

        guard let body, !body.isEmpty else { return }
        append(
            role: .event,
            title: String(localized: "codexAppServer.event.reasoning", defaultValue: "Reasoning"),
            body: body,
            presentation: .reasoning
        )
    }

    private func normalizedReasoningItemKey(_ itemId: String?) -> String {
        let trimmed = itemId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return Self.anonymousReasoningItemKey
    }

    private func appendCommandDelta(_ delta: String?, itemId: String?) {
        guard let delta, !delta.isEmpty else { return }

        let normalizedItemId = itemId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputItemId: UUID?
        if let normalizedItemId, !normalizedItemId.isEmpty {
            outputItemId = activeCommandOutputItemIDs[normalizedItemId]
        } else {
            outputItemId = anonymousCommandOutputItemID
        }

        if let outputItemId,
           let index = transcriptItems.firstIndex(where: { $0.id == outputItemId }) {
            transcriptItems[index].body = Self.truncatedTranscriptBody(transcriptItems[index].body + delta)
            transcriptItems[index].date = Date()
            return
        }

        let item = CodexAppServerTranscriptItem(
            role: .event,
            title: String(localized: "codexAppServer.event.output", defaultValue: "Output"),
            body: Self.truncatedTranscriptBody(delta),
            isStreaming: true,
            presentation: .commandOutput
        )
        transcriptItems.append(item)
        if let normalizedItemId, !normalizedItemId.isEmpty {
            activeCommandOutputItemIDs[normalizedItemId] = item.id
        } else {
            anonymousCommandOutputItemID = item.id
        }
        trimTranscriptItemsIfNeeded()
    }

    private func appendHookEvent(method: String, params: [String: Any]?) {
        let title: String
        switch method {
        case "hook/started":
            title = String(localized: "codexAppServer.event.hookStarted", defaultValue: "Hook started")
        case "hook/completed":
            title = String(localized: "codexAppServer.event.hookCompleted", defaultValue: "Hook completed")
        default:
            title = String(localized: "codexAppServer.event.hook", defaultValue: "Hook")
        }
        append(
            role: .event,
            title: title,
            body: Self.prettyJSON(params),
            presentation: .hookEvent(method: method)
        )
    }

    private func finishCommandOutput(for itemId: String?) {
        let normalizedItemId = itemId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputItemId: UUID?
        if let normalizedItemId, !normalizedItemId.isEmpty {
            outputItemId = activeCommandOutputItemIDs.removeValue(forKey: normalizedItemId)
        } else {
            outputItemId = anonymousCommandOutputItemID
            anonymousCommandOutputItemID = nil
        }
        guard let outputItemId,
              let index = transcriptItems.firstIndex(where: { $0.id == outputItemId }) else {
            return
        }
        transcriptItems[index].isStreaming = false
    }

    private func finishStreamingAssistant() {
        guard let id = activeAssistantItemId,
              let index = transcriptItems.firstIndex(where: { $0.id == id }) else {
            activeAssistantItemId = nil
            return
        }
        transcriptItems[index].isStreaming = false
        activeAssistantItemId = nil
    }

    private func finishStreamingReasoningSummaries() {
        guard !activeReasoningItemIDs.isEmpty else { return }
        let ids = Set(activeReasoningItemIDs.values)
        for index in transcriptItems.indices where ids.contains(transcriptItems[index].id) {
            transcriptItems[index].isStreaming = false
        }
        activeReasoningItemIDs.removeAll(keepingCapacity: false)
    }

    private func appendEvent(
        title: String,
        body: String,
        presentation: CodexAppServerTranscriptPresentation = .plain
    ) {
        append(role: .event, title: title, body: body, presentation: presentation)
    }

    private func appendError(_ message: String) {
        append(
            role: .error,
            title: String(localized: "codexAppServer.event.error", defaultValue: "Error"),
            body: message
        )
    }

    private func appendCodexErrorEvent(_ params: [String: Any]?) {
        let display = CodexAppServerTranscriptPolicy.codexErrorDisplay(from: params)
        append(role: .error, title: display.title, body: display.message)
    }

    private func appendStderr(_ text: String) {
        let items = stderrTranscriptBuffer.append(text)
        guard !items.isEmpty else { return }
        transcriptItems.append(contentsOf: items)
        trimTranscriptItemsIfNeeded()
    }

    private func flushPendingStderr() {
        let items = stderrTranscriptBuffer.flush()
        guard !items.isEmpty else { return }
        transcriptItems.append(contentsOf: items)
        trimTranscriptItemsIfNeeded()
    }

    private func appendCompactionEvent() {
        transcriptItems.append(
            CodexAppServerTranscriptItem(
                role: .event,
                title: String(
                    localized: "codexAppServer.event.contextCompacted",
                    defaultValue: "Context automatically compacted"
                ),
                body: "",
                presentation: .compaction
            )
        )
        trimTranscriptItemsIfNeeded()
    }

    @discardableResult
    private func applyResumeResponse(_ response: [String: Any], fallbackThreadId: String) -> CodexAppServerResumeSnapshot {
        let snapshot = Self.resumeSnapshot(
            from: response,
            fallbackThreadId: fallbackThreadId,
            restoredItemLimit: Self.restoredTranscriptItemLimit
        )
        threadId = snapshot.threadId
        if let resumedCwd = snapshot.cwd, !resumedCwd.isEmpty {
            cwd = resumedCwd
        }
        if let resumedModel = Self.stringValue(named: "model", in: response),
           !resumedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedModelId = resumedModel
        }

        activeAssistantItemId = nil
        activeReasoningItemIDs.removeAll(keepingCapacity: false)

        if snapshot.responseWasTruncated {
            return snapshot
        }

        guard !snapshot.transcriptItems.isEmpty else { return snapshot }
        if snapshot.didTruncate {
            transcriptItems = [
                    Self.historyTruncatedItem(
                        displayedCount: snapshot.transcriptItems.count,
                        totalCount: snapshot.totalRestoredItemCount,
                        totalCountIsExact: true,
                        date: snapshot.transcriptItems.first?.date
                    )
            ] + snapshot.transcriptItems
        } else {
            transcriptItems = snapshot.transcriptItems
        }
        return snapshot
    }

    private func startInitialHistoryRestore(threadId: String, generation: Int) {
        let sanitizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedThreadId.isEmpty else { return }

        initialHistoryRestoreTask?.cancel()
        initialHistoryRestoreThreadId = sanitizedThreadId
#if DEBUG
        CodexAppServerTiming.log("localHistory.prefetch.scheduled", [
            "panel": id.uuidString.prefix(8),
            "thread": sanitizedThreadId,
            "limit": Self.localHistoryItemLimit,
        ])
#endif
        initialHistoryRestoreTask = Task { [weak self] in
#if DEBUG
            let loadStart = CodexAppServerTiming.now()
#endif
            let snapshot = await CodexSessionHistoryLoader.loadHistory(
                threadId: sanitizedThreadId,
                limit: Self.localHistoryItemLimit
            )
#if DEBUG
            CodexAppServerTiming.log("localHistory.prefetch.loaded", [
                "thread": sanitizedThreadId,
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: loadStart)),
                "items": snapshot.transcriptItems.count,
                "total": snapshot.totalDisplayableItemCount,
                "exact_total": snapshot.totalDisplayableItemCountIsExact,
                "truncated": snapshot.didTruncate,
                "file": snapshot.fileURL?.lastPathComponent,
            ])
#endif
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentLifecycle(generation),
                      self.normalizedThreadId(self.threadId) == sanitizedThreadId else {
                    return
                }
                self.applyLocalHistory(snapshot, showEmptyFallback: false)
            }
            return snapshot
        }
    }

    private func loadLocalHistory(for threadId: String, generation: Int) async {
        transcriptLoadingPhase = .restoringHistory
        let sanitizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedThreadId = normalizedThreadId(sanitizedThreadId)
#if DEBUG
        let loadStart = CodexAppServerTiming.now()
        CodexAppServerTiming.log("localHistory.fallback.begin", [
            "panel": id.uuidString.prefix(8),
            "thread": sanitizedThreadId,
            "limit": Self.localHistoryItemLimit,
        ])
#endif
        let snapshot: CodexSessionHistorySnapshot
        if initialHistoryRestoreThreadId == sanitizedThreadId,
           let initialHistoryRestoreTask {
#if DEBUG
            let reuseStart = CodexAppServerTiming.now()
#endif
            snapshot = await initialHistoryRestoreTask.value
#if DEBUG
            CodexAppServerTiming.log("localHistory.fallback.reusedPrefetch", [
                "panel": id.uuidString.prefix(8),
                "thread": sanitizedThreadId,
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: reuseStart)),
                "items": snapshot.transcriptItems.count,
                "total": snapshot.totalDisplayableItemCount,
                "exact_total": snapshot.totalDisplayableItemCountIsExact,
            ])
#endif
        } else {
            snapshot = await CodexSessionHistoryLoader.loadHistory(
                threadId: sanitizedThreadId,
                limit: Self.localHistoryItemLimit
            )
        }
        guard let expectedThreadId,
              isCurrentLifecycle(generation),
              normalizedThreadId(self.threadId) == expectedThreadId else {
            return
        }
#if DEBUG
        CodexAppServerTiming.log("localHistory.fallback.loaded", [
            "panel": id.uuidString.prefix(8),
            "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: loadStart)),
            "items": snapshot.transcriptItems.count,
            "total": snapshot.totalDisplayableItemCount,
            "exact_total": snapshot.totalDisplayableItemCountIsExact,
            "truncated": snapshot.didTruncate,
            "file": snapshot.fileURL?.lastPathComponent,
        ])
#endif
        applyLocalHistory(snapshot, showEmptyFallback: true)
    }

    private func applyLocalHistory(_ snapshot: CodexSessionHistorySnapshot, showEmptyFallback: Bool) {
#if DEBUG
        let applyStart = CodexAppServerTiming.now()
        defer {
            CodexAppServerTiming.logSlow("localHistory.apply", start: applyStart, thresholdMs: 2, [
                "panel": id.uuidString.prefix(8),
                "snapshot_items": snapshot.transcriptItems.count,
                "snapshot_total": snapshot.totalDisplayableItemCount,
                "transcript_items": transcriptItems.count,
            ])
        }
#endif
        guard !snapshot.transcriptItems.isEmpty else {
            if showEmptyFallback {
                appendEvent(
                    title: String(localized: "codexAppServer.event.historyOmitted", defaultValue: "History omitted"),
                    body: String(
                        localized: "codexAppServer.event.historyOmitted.body",
                        defaultValue: "Codex returned a very large history. The thread is connected, and new messages will stream here."
                    )
                )
            }
            return
        }

        if !transcriptItems.isEmpty,
           snapshot.totalDisplayableItemCount <= transcriptItems.count {
            return
        }

        activeAssistantItemId = nil
        if snapshot.didTruncate {
            transcriptItems = [
                Self.historyTruncatedItem(
                    displayedCount: snapshot.transcriptItems.count,
                    totalCount: snapshot.totalDisplayableItemCount,
                    totalCountIsExact: snapshot.totalDisplayableItemCountIsExact,
                    date: snapshot.transcriptItems.first?.date
                )
            ] + snapshot.transcriptItems
        } else {
            transcriptItems = snapshot.transcriptItems
        }
    }

    static func resumeSnapshot(
        from response: [String: Any],
        fallbackThreadId: String,
        restoredItemLimit: Int
    ) -> CodexAppServerResumeSnapshot {
#if DEBUG
        let start = CodexAppServerTiming.now()
        var debugTurnCount = 0
        var debugRawItemCount = 0
        defer {
            CodexAppServerTiming.logSlow("resumeSnapshot.parse", start: start, thresholdMs: 2, [
                "thread": fallbackThreadId,
                "turns": debugTurnCount,
                "raw_items": debugRawItemCount,
                "limit": restoredItemLimit,
            ])
        }
#endif
        let thread = response["thread"] as? [String: Any]
        let resolvedThreadId = Self.stringValue(named: "id", in: thread) ?? fallbackThreadId
        let resolvedCwd = Self.stringValue(named: "cwd", in: response)
            ?? Self.stringValue(named: "cwd", in: thread)
        let responseWasTruncated = (response["_cmuxResponseTruncated"] as? Bool) == true
        guard !responseWasTruncated else {
            return CodexAppServerResumeSnapshot(
                threadId: resolvedThreadId,
                cwd: resolvedCwd,
                transcriptItems: [],
                totalRestoredItemCount: 0,
                didTruncate: false,
                responseWasTruncated: true
            )
        }

        let turns = thread?["turns"] as? [[String: Any]] ?? []
#if DEBUG
        debugTurnCount = turns.count
#endif
        var restoredItems: [CodexAppServerTranscriptItem] = []
        for turn in turns {
            let date = Self.dateValue(named: "startedAt", in: turn) ?? Date()
            let items = turn["items"] as? [[String: Any]] ?? []
#if DEBUG
            debugRawItemCount += items.count
#endif
            for item in items {
                if let restoredItem = restoredTranscriptItem(fromThreadItem: item, date: date) {
                    restoredItems.append(restoredItem)
                }
            }
        }

        let totalRestoredItemCount = restoredItems.count
        let limit = max(1, restoredItemLimit)
        let didTruncate = totalRestoredItemCount > limit
        if didTruncate {
            restoredItems = Array(restoredItems.suffix(limit))
        }

        return CodexAppServerResumeSnapshot(
            threadId: resolvedThreadId,
            cwd: resolvedCwd,
            transcriptItems: restoredItems,
            totalRestoredItemCount: totalRestoredItemCount,
            didTruncate: didTruncate,
            responseWasTruncated: false
        )
    }

    private static func historyTruncatedItem(
        displayedCount: Int,
        totalCount: Int,
        totalCountIsExact: Bool,
        date: Date?
    ) -> CodexAppServerTranscriptItem {
        let body: String
        if totalCountIsExact {
            let format = String(
                localized: "codexAppServer.event.historyTruncated.body",
                defaultValue: "Showing the latest %1$ld of %2$ld history items."
            )
            body = String(
                format: format,
                locale: Locale.current,
                displayedCount,
                totalCount
            )
        } else {
            let format = String(
                localized: "codexAppServer.event.historyTruncated.approximateBody",
                defaultValue: "Showing the latest %ld history items. Earlier history is omitted."
            )
            body = String(
                format: format,
                locale: Locale.current,
                displayedCount
            )
        }
        return CodexAppServerTranscriptItem(
            role: .event,
            title: String(localized: "codexAppServer.event.historyTruncated", defaultValue: "Earlier history omitted"),
            body: body,
            date: date ?? Date()
        )
    }

    private static func restoredTranscriptItem(
        fromThreadItem item: [String: Any],
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        let type = Self.stringValue(named: "type", in: item) ?? ""
        switch type {
        case "userMessage":
            guard let text = Self.userMessageText(from: item), !text.isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .user,
                title: String(localized: "codexAppServer.role.user", defaultValue: "You"),
                body: Self.truncatedTranscriptBody(text),
                date: date
            )
        case "agentMessage":
            guard let text = Self.stringValue(named: "text", in: item), !text.isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .assistant,
                title: String(localized: "codexAppServer.role.assistant", defaultValue: "Codex"),
                body: Self.truncatedTranscriptBody(text),
                date: date
            )
        case "plan":
            guard let text = Self.stringValue(named: "text", in: item), !text.isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(localized: "codexAppServer.event.plan", defaultValue: "Plan"),
                body: Self.truncatedTranscriptBody(text),
                date: date
            )
        case "reasoning":
            guard let summary = Self.reasoningSummaryText(from: item), !summary.isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(localized: "codexAppServer.event.reasoning", defaultValue: "Reasoning"),
                body: Self.truncatedTranscriptBody(summary),
                date: date,
                presentation: .reasoning
            )
        case "commandExecution":
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(localized: "codexAppServer.event.command", defaultValue: "Command"),
                body: Self.truncatedTranscriptBody(Self.commandSummary(from: item)),
                date: date,
                presentation: .toolCall(name: "shell")
            )
        case "fileChange":
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(localized: "codexAppServer.event.fileChange", defaultValue: "File change"),
                body: Self.truncatedTranscriptBody(Self.prettyJSON(item)),
                date: date,
                presentation: .toolCall(name: "apply_patch")
            )
        case "error":
            let display = CodexAppServerTranscriptPolicy.codexErrorDisplay(from: item)
            return CodexAppServerTranscriptItem(
                role: .error,
                title: display.title,
                body: Self.truncatedTranscriptBody(display.message),
                date: date
            )
        default:
            let body = Self.stringValue(named: "text", in: item) ?? Self.prettyJSON(item)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .event,
                title: type.isEmpty
                    ? String(localized: "codexAppServer.event.item", defaultValue: "Item")
                    : type,
                body: Self.truncatedTranscriptBody(body),
                date: date
            )
        }
    }

    @discardableResult
    private func append(
        role: CodexAppServerTranscriptRole,
        title: String,
        body: String,
        presentation: CodexAppServerTranscriptPresentation = .plain,
        preservesBodyWhitespace: Bool = false
    ) -> CodexAppServerTranscriptItem? {
        let rawBody = preservesBodyWhitespace ? body : body.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = Self.truncatedTranscriptBody(rawBody)
        guard !trimmedBody.isEmpty else { return nil }
        let item = CodexAppServerTranscriptItem(
            role: role,
            title: title,
            body: trimmedBody,
            presentation: presentation
        )
        transcriptItems.append(item)
        trimTranscriptItemsIfNeeded()
        return item
    }

    private func trimTranscriptItemsIfNeeded() {
        let overflow = transcriptItems.count - Self.maxTranscriptItems
        guard overflow > 0 else { return }

        var remainingToRemove = overflow
        transcriptItems.removeAll { item in
            guard remainingToRemove > 0 else { return false }
            if let activeAssistantItemId, item.id == activeAssistantItemId {
                return false
            }
            remainingToRemove -= 1
            return true
        }
    }

    private func preserveRenderedUserItemsAfterResume(_ items: [CodexAppServerTranscriptItem]) {
        guard !items.isEmpty else { return }
        let existingItemIDs = Set(transcriptItems.map(\.id))
        let additions = items.filter { item in
            !existingItemIDs.contains(item.id)
                && !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !additions.isEmpty else { return }
        transcriptItems.append(contentsOf: additions)
        trimTranscriptItemsIfNeeded()
    }

    private static func truncatedTranscriptBody(_ body: String) -> String {
        CodexAppServerTranscriptPolicy.truncatedBody(body)
    }

    private func removePendingRequest(id: Int) {
        removePendingRequest(id: .int(id))
    }

    private func removePendingRequest(id: CodexAppServerRequestID) {
        pendingRequests.removeAll { $0.id == id }
    }

    private func removeResolvedServerRequest(_ params: [String: Any]?) {
        for key in ["id", "requestId", "requestID", "serverRequestId"] {
            guard let id = Self.requestIDValue(named: key, in: params) else { continue }
            removePendingRequest(id: id)
            return
        }
    }

    private func currentWorkingDirectory() -> String {
        cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizedCodexThreadId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let prefix = "urn:uuid:"
        let bareThreadId: String
        if trimmed.lowercased().hasPrefix(prefix) {
            bareThreadId = String(trimmed.dropFirst(prefix.count))
        } else {
            bareThreadId = trimmed
        }

        guard UUID(uuidString: bareThreadId) != nil else { return nil }
        return bareThreadId.lowercased()
    }

    private func normalizedThreadId(_ value: String?) -> String? {
        Self.normalizedCodexThreadId(value)
    }

    private static func stringValue(named key: String, in object: [String: Any]?) -> String? {
        guard let value = object?[key] else { return nil }
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func reasoningSummaryText(from item: [String: Any]) -> String? {
        let summary = reasoningTextEntries(from: item["summary"])
        if !summary.isEmpty {
            return normalizedReasoningSummary(summary.joined(separator: "\n\n"))
        }
        return nil
    }

    private static func reasoningTextEntries(from value: Any?) -> [String] {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let entries = value as? [String] {
            return entries.compactMap { entry in
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        if let entries = value as? [[String: Any]] {
            return entries.compactMap { entry in
                let text = stringValue(named: "text", in: entry)
                    ?? stringValue(named: "content", in: entry)
                    ?? stringValue(named: "summary", in: entry)
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
        }
        return []
    }

    private static func normalizedReasoningSummary(_ text: String) -> String? {
        CodexReasoningSummaryNormalizer.normalized(text)
    }

    nonisolated static func requestIDValue(named key: String, in object: [String: Any]?) -> CodexAppServerRequestID? {
        CodexAppServerClient.requestID(from: object?[key])
    }

    private static func itemIdentifier(from item: [String: Any]) -> String? {
        stringValue(named: "id", in: item)
            ?? stringValue(named: "itemId", in: item)
    }

    private static func dateValue(named key: String, in object: [String: Any]?) -> Date? {
        guard let value = object?[key] else { return nil }
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = TimeInterval(trimmed) {
                return Date(timeIntervalSince1970: seconds)
            }
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: trimmed) {
                return date
            }
            return ISO8601DateFormatter().date(from: trimmed)
        }
        if let value = value as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    private static func userMessageText(from item: [String: Any]) -> String? {
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { input -> String? in
            if let text = stringValue(named: "text", in: input) {
                return text
            }
            if let url = stringValue(named: "url", in: input) {
                return url
            }
            return nil
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func commandSummary(from item: [String: Any]) -> String {
        if let command = item["command"] as? String {
            return command
        }
        if let command = item["command"] as? [String] {
            return command.joined(separator: " ")
        }
        return Self.prettyJSON(item)
    }

    private static func prettyJSON(_ value: Any?) -> String {
        guard let value else { return "{}" }
        let object: Any
        if JSONSerialization.isValidJSONObject(value) {
            object = value
        } else {
            object = ["value": String(describing: value)]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}

private enum CodexReasoningSummaryNormalizer {
    private static let knownLeadingLabels: Set<String> = [
        "analysis",
        "reasoning",
        "summary",
        "thinking",
        "thought",
        "thoughts",
    ]

    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard trimmed.hasPrefix("**"),
              let open = trimmed.range(of: "**") else {
            return trimmed
        }
        let afterOpen = trimmed[open.upperBound...]
        guard let close = afterOpen.range(of: "**") else {
            return trimmed
        }

        let heading = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heading.isEmpty else { return trimmed }

        let rawAfterClose = afterOpen[close.upperBound...]
        let afterClose = removingLeadingLabelSeparator(from: rawAfterClose)
        guard !afterClose.isEmpty else { return heading }

        if rawAfterClose.unicodeScalars.first.map({ CharacterSet.newlines.contains($0) }) == true {
            return afterClose
        }

        let normalizedHeading = heading
            .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
            .lowercased()
        if heading.hasSuffix(":") || heading.hasSuffix("：") || knownLeadingLabels.contains(normalizedHeading) {
            return afterClose
        }

        return trimmed
    }

    private static func removingLeadingLabelSeparator(from text: Substring) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == ":" || trimmed.first == "：" {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

enum CodexSessionHistoryLoader {
    private static let chunkSize = 1024 * 1024
    private static let largeHistoryTailParsingThreshold = 64 * 1024 * 1024
    private static let initialTailParseByteLimit = 32 * 1024 * 1024
    private static let maxTailParseByteLimit = 128 * 1024 * 1024
    private static let eventMessageNeedle = Data(#""type":"event_msg""#.utf8)
    private static let contextCompactedNeedle = Data(#""type":"context_compacted""#.utf8)
    private static let userMessageNeedle = Data(#""type":"user_message""#.utf8)
    private static let warningNeedle = Data(#""type":"warning""#.utf8)
    private static let errorNeedle = Data(#""type":"error""#.utf8)
    private static let responseItemNeedle = Data(#""type":"response_item""#.utf8)
    private static let messageNeedle = Data(#""type":"message""#.utf8)
    private static let assistantRoleNeedle = Data(#""role":"assistant""#.utf8)
    private static let reasoningNeedle = Data(#""type":"reasoning""#.utf8)
    private static let functionCallNeedle = Data(#""type":"function_call""#.utf8)
    private static let functionCallOutputNeedle = Data(#""type":"function_call_output""#.utf8)
    private static let customToolCallNeedle = Data(#""type":"custom_tool_call""#.utf8)

    static func loadHistory(threadId: String, limit: Int) async -> CodexSessionHistorySnapshot {
        await Task.detached(priority: .utility) {
            loadHistorySync(threadId: threadId, limit: limit)
        }.value
    }

    static func loadHistorySync(
        threadId: String,
        limit: Int,
        searchRoots: [URL]? = nil,
        tailParsingThreshold: Int = largeHistoryTailParsingThreshold,
        tailInitialReadLimit: Int = initialTailParseByteLimit,
        tailMaxReadLimit: Int = maxTailParseByteLimit
    ) -> CodexSessionHistorySnapshot {
#if DEBUG
        let start = CodexAppServerTiming.now()
#endif
        let sanitizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedThreadId.isEmpty else {
            return emptySnapshot(threadId: threadId, fileURL: nil)
        }

        let roots = searchRoots ?? defaultSearchRoots()
        guard let fileURL = historyFile(threadId: sanitizedThreadId, searchRoots: roots) else {
#if DEBUG
            CodexAppServerTiming.log("localHistory.load.missing", [
                "thread": sanitizedThreadId,
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
                "roots": roots.map(\.path).joined(separator: ","),
            ])
#endif
            return emptySnapshot(threadId: sanitizedThreadId, fileURL: nil)
        }

        let snapshot = parseHistoryFile(
            fileURL,
            threadId: sanitizedThreadId,
            limit: limit,
            tailParsingThreshold: tailParsingThreshold,
            tailInitialReadLimit: tailInitialReadLimit,
            tailMaxReadLimit: tailMaxReadLimit
        )
#if DEBUG
        CodexAppServerTiming.log("localHistory.load.end", [
            "thread": sanitizedThreadId,
            "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
            "items": snapshot.transcriptItems.count,
            "total": snapshot.totalDisplayableItemCount,
            "exact_total": snapshot.totalDisplayableItemCountIsExact,
            "truncated": snapshot.didTruncate,
            "file": fileURL.lastPathComponent,
        ])
#endif
        return snapshot
    }

    private static func defaultSearchRoots() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        let configuredCodexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHome = if let configuredCodexHome, !configuredCodexHome.isEmpty {
            URL(fileURLWithPath: configuredCodexHome, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    private static func emptySnapshot(threadId: String, fileURL: URL?) -> CodexSessionHistorySnapshot {
        CodexSessionHistorySnapshot(
            threadId: threadId,
            fileURL: fileURL,
            transcriptItems: [],
            totalDisplayableItemCount: 0,
            totalDisplayableItemCountIsExact: true,
            didTruncate: false
        )
    }

    private static func historyFile(threadId: String, searchRoots: [URL]) -> URL? {
#if DEBUG
        let start = CodexAppServerTiming.now()
#endif
        var jsonlFiles: [URL] = []
        var visitedURLCount = 0
        for root in searchRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                visitedURLCount += 1
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard isRegularFile(fileURL) else { continue }
                jsonlFiles.append(fileURL)
            }
        }

        let filenameMatches = jsonlFiles.filter { $0.lastPathComponent.contains(threadId) }
        if let match = sortedMostRecentlyModified(filenameMatches).first {
#if DEBUG
            CodexAppServerTiming.log("localHistory.search.end", [
                "thread": threadId,
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
                "roots": searchRoots.count,
                "visited": visitedURLCount,
                "jsonl": jsonlFiles.count,
                "filename_matches": filenameMatches.count,
                "metadata_scanned": 0,
                "result": match.path,
            ])
#endif
            return match
        }

        var metadataScanned = 0
        let metadataMatches = jsonlFiles.filter {
            metadataScanned += 1
            return sessionMetadataMatches(fileURL: $0, threadId: threadId)
        }
        let result = sortedMostRecentlyModified(metadataMatches).first
#if DEBUG
        CodexAppServerTiming.log("localHistory.search.end", [
            "thread": threadId,
            "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
            "roots": searchRoots.count,
            "visited": visitedURLCount,
            "jsonl": jsonlFiles.count,
            "filename_matches": filenameMatches.count,
            "metadata_scanned": metadataScanned,
            "metadata_matches": metadataMatches.count,
            "result": result?.path,
        ])
#endif
        return result
    }

    private static func sortedMostRecentlyModified(_ files: [URL]) -> [URL] {
        files.sorted { lhs, rhs in
            modificationDate(lhs) > modificationDate(rhs)
        }
    }

    private static func modificationDate(_ fileURL: URL) -> Date {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func isRegularFile(_ fileURL: URL) -> Bool {
        (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func sessionMetadataMatches(fileURL: URL, threadId: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else {
            return false
        }
        let idNeedle = Data(("\"id\":\"\(threadId)\"").utf8)
        return data.range(of: idNeedle) != nil
    }

    private static func parseHistoryFile(
        _ fileURL: URL,
        threadId: String,
        limit: Int,
        tailParsingThreshold: Int = largeHistoryTailParsingThreshold,
        tailInitialReadLimit: Int = initialTailParseByteLimit,
        tailMaxReadLimit: Int = maxTailParseByteLimit
    ) -> CodexSessionHistorySnapshot {
        let resolvedLimit = max(1, limit)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return emptySnapshot(threadId: threadId, fileURL: fileURL)
        }
        defer { try? handle.close() }

        let fileByteSize = (try? handle.seekToEnd()) ?? 0
        if fileByteSize > UInt64(max(0, tailParsingThreshold)),
           let snapshot = parseTailHistoryFile(
                fileURL,
                handle: handle,
                fileByteSize: fileByteSize,
                threadId: threadId,
                limit: resolvedLimit,
                initialReadLimit: tailInitialReadLimit,
                maxReadLimit: tailMaxReadLimit
           ) {
            return snapshot
        }

        return parseForwardHistoryFile(
            fileURL,
            handle: handle,
            threadId: threadId,
            limit: resolvedLimit
        )
    }

    private static func parseForwardHistoryFile(
        _ fileURL: URL,
        handle: FileHandle,
        threadId: String,
        limit: Int
    ) -> CodexSessionHistorySnapshot {
#if DEBUG
        let start = CodexAppServerTiming.now()
#endif
        try? handle.seek(toOffset: 0)

        var lineBuffer = CodexAppServerLineBuffer()
        var transcriptItems: [CodexAppServerTranscriptItem] = []
        var totalDisplayableItemCount = 0
        var chunkCount = 0
        var byteCount = 0
        var lineCount = 0
        var candidateLineCount = 0
        var parsedLineCount = 0

        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else {
                break
            }
            chunkCount += 1
            byteCount += chunk.count
            for line in lineBuffer.append(chunk) {
                consumeHistoryLine(
                    line,
                    resolvedLimit: limit,
                    transcriptItems: &transcriptItems,
                    totalDisplayableItemCount: &totalDisplayableItemCount,
                    lineCount: &lineCount,
                    candidateLineCount: &candidateLineCount,
                    parsedLineCount: &parsedLineCount
                )
            }
        }
        if let finalLine = lineBuffer.finish() {
            consumeHistoryLine(
                finalLine,
                resolvedLimit: limit,
                transcriptItems: &transcriptItems,
                totalDisplayableItemCount: &totalDisplayableItemCount,
                lineCount: &lineCount,
                candidateLineCount: &candidateLineCount,
                parsedLineCount: &parsedLineCount
            )
        }

        if transcriptItems.count > limit {
            transcriptItems = Array(transcriptItems.suffix(limit))
        }

        let snapshot = CodexSessionHistorySnapshot(
            threadId: threadId,
            fileURL: fileURL,
            transcriptItems: transcriptItems,
            totalDisplayableItemCount: totalDisplayableItemCount,
            totalDisplayableItemCountIsExact: true,
            didTruncate: totalDisplayableItemCount > transcriptItems.count
        )
#if DEBUG
        CodexAppServerTiming.log("localHistory.parse.end", [
            "thread": threadId,
            "mode": "forward",
            "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
            "file": fileURL.lastPathComponent,
            "mb": String(format: "%.1f", Double(byteCount) / 1_048_576),
            "chunks": chunkCount,
            "lines": lineCount,
            "candidates": candidateLineCount,
            "parsed": parsedLineCount,
            "items": transcriptItems.count,
            "total": totalDisplayableItemCount,
            "truncated": totalDisplayableItemCount > transcriptItems.count,
        ])
#endif
        return snapshot
    }

    private static func parseTailHistoryFile(
        _ fileURL: URL,
        handle: FileHandle,
        fileByteSize: UInt64,
        threadId: String,
        limit: Int,
        initialReadLimit: Int,
        maxReadLimit: Int
    ) -> CodexSessionHistorySnapshot? {
#if DEBUG
        let start = CodexAppServerTiming.now()
#endif
        var readLimit = min(
            fileByteSize,
            UInt64(max(1, min(initialReadLimit, maxReadLimit)))
        )
        let maxTailBytes = min(fileByteSize, UInt64(max(1, maxReadLimit)))
        var attemptCount = 0

        while true {
            attemptCount += 1
            let offset = fileByteSize - readLimit
            let skipFirstLine: Bool
            if offset > 0 {
                do {
                    try handle.seek(toOffset: offset - 1)
                    let previousByte = try handle.read(upToCount: 1)
                    skipFirstLine = previousByte?.first != 0x0A
                } catch {
                    skipFirstLine = true
                }
            } else {
                skipFirstLine = false
            }

            let data: Data
            do {
                try handle.seek(toOffset: offset)
                data = try handle.read(upToCount: Int(readLimit)) ?? Data()
            } catch {
                return nil
            }

            let parsed = parseTailHistoryData(
                data,
                threadId: threadId,
                fileURL: fileURL,
                limit: limit,
                skipFirstLine: skipFirstLine,
                omittedPrefix: offset > 0
            )

            if parsed.transcriptItems.count >= limit || offset == 0 {
#if DEBUG
                CodexAppServerTiming.log("localHistory.parse.end", [
                    "thread": threadId,
                    "mode": "tail",
                    "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
                    "file": fileURL.lastPathComponent,
                    "file_mb": String(format: "%.1f", Double(fileByteSize) / 1_048_576),
                    "read_mb": String(format: "%.1f", Double(data.count) / 1_048_576),
                    "attempts": attemptCount,
                    "items": parsed.transcriptItems.count,
                    "total": parsed.totalDisplayableItemCount,
                    "exact_total": parsed.totalDisplayableItemCountIsExact,
                    "truncated": parsed.didTruncate,
                ])
#endif
                return parsed
            }

            guard readLimit < maxTailBytes else {
#if DEBUG
                CodexAppServerTiming.log("localHistory.parse.tailFallback", [
                    "thread": threadId,
                    "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
                    "file": fileURL.lastPathComponent,
                    "read_mb": String(format: "%.1f", Double(readLimit) / 1_048_576),
                    "items": parsed.transcriptItems.count,
                    "limit": limit,
                ])
#endif
                try? handle.seek(toOffset: 0)
                return nil
            }
            readLimit = min(maxTailBytes, readLimit * 2)
        }
    }

    private static func parseHistoryData(
        _ data: Data,
        threadId: String,
        fileURL: URL,
        limit: Int,
        skipFirstLine: Bool,
        omittedPrefix: Bool,
        chunkCount: Int
    ) -> CodexSessionHistorySnapshot {
        var lineBuffer = CodexAppServerLineBuffer()
        var transcriptItems: [CodexAppServerTranscriptItem] = []
        var totalDisplayableItemCount = 0
        var lineCount = 0
        var candidateLineCount = 0
        var parsedLineCount = 0
        var shouldSkipNextLine = skipFirstLine

        func consumeIfComplete(_ line: Data) {
            if shouldSkipNextLine {
                shouldSkipNextLine = false
                return
            }
            consumeHistoryLine(
                line,
                resolvedLimit: limit,
                transcriptItems: &transcriptItems,
                totalDisplayableItemCount: &totalDisplayableItemCount,
                lineCount: &lineCount,
                candidateLineCount: &candidateLineCount,
                parsedLineCount: &parsedLineCount
            )
        }

        for line in lineBuffer.append(data) {
            consumeIfComplete(line)
        }
        if let finalLine = lineBuffer.finish() {
            consumeIfComplete(finalLine)
        }

        if transcriptItems.count > limit {
            transcriptItems = Array(transcriptItems.suffix(limit))
        }
        let exactTotal = !omittedPrefix
        let reportedTotal = exactTotal
            ? totalDisplayableItemCount
            : max(totalDisplayableItemCount + 1, transcriptItems.count + 1)
        return CodexSessionHistorySnapshot(
            threadId: threadId,
            fileURL: fileURL,
            transcriptItems: transcriptItems,
            totalDisplayableItemCount: reportedTotal,
            totalDisplayableItemCountIsExact: exactTotal,
            didTruncate: omittedPrefix || totalDisplayableItemCount > transcriptItems.count
        )
    }

    private static func parseTailHistoryData(
        _ data: Data,
        threadId: String,
        fileURL: URL,
        limit: Int,
        skipFirstLine: Bool,
        omittedPrefix: Bool
    ) -> CodexSessionHistorySnapshot {
        var reversedItems: [CodexAppServerTranscriptItem] = []
        reversedItems.reserveCapacity(limit)
        var foundOlderDisplayableItem = false

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var lineEnd = data.count
            var index = data.count

            func displayableItem(start: Int, end: Int) -> CodexAppServerTranscriptItem? {
                guard end > start else { return nil }
                if skipFirstLine && start == 0 { return nil }
                let line = Data(bytes: base.advanced(by: start), count: end - start)
                guard shouldParseLine(line),
                      let item = transcriptItem(from: line) else {
                    return nil
                }
                return item
            }

            while index > 0 && reversedItems.count < limit {
                index -= 1
                guard base[index] == 0x0A else { continue }
                if let item = displayableItem(start: index + 1, end: lineEnd) {
                    reversedItems.append(item)
                }
                lineEnd = index
            }

            if reversedItems.count < limit {
                if let item = displayableItem(start: 0, end: lineEnd) {
                    reversedItems.append(item)
                }
            } else if !omittedPrefix {
                var prefixLineEnd = lineEnd
                var prefixIndex = index
                while prefixIndex > 0 && !foundOlderDisplayableItem {
                    prefixIndex -= 1
                    guard base[prefixIndex] == 0x0A else { continue }
                    foundOlderDisplayableItem = displayableItem(
                        start: prefixIndex + 1,
                        end: prefixLineEnd
                    ) != nil
                    prefixLineEnd = prefixIndex
                }
                if !foundOlderDisplayableItem {
                    foundOlderDisplayableItem = displayableItem(start: 0, end: prefixLineEnd) != nil
                }
            }
        }

        let transcriptItems = reversedItems.reversed()
        let exactTotal = !omittedPrefix && !foundOlderDisplayableItem
        let reportedTotal = exactTotal
            ? transcriptItems.count
            : max(transcriptItems.count + 1, limit + 1)
        return CodexSessionHistorySnapshot(
            threadId: threadId,
            fileURL: fileURL,
            transcriptItems: Array(transcriptItems),
            totalDisplayableItemCount: reportedTotal,
            totalDisplayableItemCountIsExact: exactTotal,
            didTruncate: omittedPrefix || foundOlderDisplayableItem
        )
    }

    private static func consumeHistoryLine(
        _ line: Data,
        resolvedLimit: Int,
        transcriptItems: inout [CodexAppServerTranscriptItem],
        totalDisplayableItemCount: inout Int,
        lineCount: inout Int,
        candidateLineCount: inout Int,
        parsedLineCount: inout Int
    ) {
        lineCount += 1
        guard shouldParseLine(line) else {
            return
        }
        candidateLineCount += 1
        guard let item = transcriptItem(from: line) else {
            return
        }
        parsedLineCount += 1
        totalDisplayableItemCount += 1
        transcriptItems.append(item)
        if transcriptItems.count > resolvedLimit * 2 {
            transcriptItems.removeFirst(transcriptItems.count - resolvedLimit)
        }
    }

    private static func shouldParseLine(_ line: Data) -> Bool {
        if line.range(of: eventMessageNeedle) != nil {
            return line.range(of: contextCompactedNeedle) != nil
                || line.range(of: userMessageNeedle) != nil
                || line.range(of: warningNeedle) != nil
                || line.range(of: errorNeedle) != nil
        }
        guard line.range(of: responseItemNeedle) != nil else { return false }
        if line.range(of: messageNeedle) != nil {
            return line.range(of: assistantRoleNeedle) != nil
        }
        return line.range(of: reasoningNeedle) != nil
            || line.range(of: functionCallNeedle) != nil
            || line.range(of: functionCallOutputNeedle) != nil
            || line.range(of: customToolCallNeedle) != nil
    }

    private static func transcriptItem(from line: Data) -> CodexAppServerTranscriptItem? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let objectType = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }

        let date = dateValue(named: "timestamp", in: object) ?? Date()
        if objectType == "event_msg" {
            return eventMessageTranscriptItem(from: payload, date: date)
        }

        guard objectType == "response_item" else { return nil }
        switch stringValue(named: "type", in: payload) {
        case "message":
            return messageTranscriptItem(from: payload, date: date)
        case "reasoning":
            return reasoningTranscriptItem(from: payload, date: date)
        case "function_call":
            return functionCallTranscriptItem(from: payload, date: date)
        case "function_call_output":
            return functionCallOutputTranscriptItem(from: payload, date: date)
        case "custom_tool_call":
            return customToolCallTranscriptItem(from: payload, date: date)
        default:
            return nil
        }
    }

    private static func eventMessageTranscriptItem(
        from payload: [String: Any],
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        switch stringValue(named: "type", in: payload) {
        case "context_compacted":
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(
                    localized: "codexAppServer.event.contextCompacted",
                    defaultValue: "Context automatically compacted"
                ),
                body: "",
                date: date,
                presentation: .compaction
            )
        case "user_message":
            guard let text = stringValue(named: "message", in: payload)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty else {
                return nil
            }
            return CodexAppServerTranscriptItem(
                role: .user,
                title: String(localized: "codexAppServer.role.user", defaultValue: "You"),
                body: CodexAppServerTranscriptPolicy.truncatedBody(text),
                date: date
            )
        case "warning":
            guard let message = stringValue(named: "message", in: payload)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !message.isEmpty else {
                return nil
            }
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(localized: "codexAppServer.event.warning", defaultValue: "Warning"),
                body: CodexAppServerTranscriptPolicy.truncatedBody(
                    CodexAppServerTranscriptPolicy.normalizedWarningMessage(message)
                ),
                date: date,
                presentation: .warning
            )
        case "error":
            let display = CodexAppServerTranscriptPolicy.codexErrorDisplay(from: payload)
            return CodexAppServerTranscriptItem(
                role: .error,
                title: display.title,
                body: CodexAppServerTranscriptPolicy.truncatedBody(display.message),
                date: date
            )
        default:
            return nil
        }
    }

    private static func messageTranscriptItem(
        from payload: [String: Any],
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        let role = stringValue(named: "role", in: payload)
        let transcriptRole: CodexAppServerTranscriptRole
        let title: String
        switch role {
        case "user":
            return nil
        case "assistant":
            transcriptRole = .assistant
            title = String(localized: "codexAppServer.role.assistant", defaultValue: "Codex")
        default:
            return nil
        }

        guard let text = messageText(from: payload["content"]), !text.isEmpty else {
            return nil
        }
        return CodexAppServerTranscriptItem(
            role: transcriptRole,
            title: title,
            body: CodexAppServerTranscriptPolicy.truncatedBody(text),
            date: date
        )
    }

    private static func reasoningTranscriptItem(
        from payload: [String: Any],
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        guard let summary = reasoningSummaryText(from: payload), !summary.isEmpty else {
            return nil
        }
        return CodexAppServerTranscriptItem(
            role: .event,
            title: String(localized: "codexAppServer.event.reasoning", defaultValue: "Reasoning"),
            body: CodexAppServerTranscriptPolicy.truncatedBody(summary),
            date: date,
            presentation: .reasoning
        )
    }

    private static func functionCallTranscriptItem(
        from payload: [String: Any],
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        let name = stringValue(named: "name", in: payload)
        let body = functionCallBody(from: payload).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let title = (name?.isEmpty == false ? name : nil)
            ?? String(localized: "codexAppServer.event.toolCall", defaultValue: "Tool call")
        return CodexAppServerTranscriptItem(
            role: .event,
            title: title,
            body: CodexAppServerTranscriptPolicy.truncatedBody(body),
            date: date,
            presentation: .toolCall(name: name)
        )
    }

    private static func functionCallOutputTranscriptItem(
        from payload: [String: Any],
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        guard let output = stringValue(named: "output", in: payload)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }
        return CodexAppServerTranscriptItem(
            role: .event,
            title: String(localized: "codexAppServer.event.toolOutput", defaultValue: "Tool output"),
            body: CodexAppServerTranscriptPolicy.truncatedBody(output),
            date: date,
            presentation: .toolOutput
        )
    }

    private static func customToolCallTranscriptItem(
        from payload: [String: Any],
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        let name = stringValue(named: "name", in: payload)
        let body = (stringValue(named: "input", in: payload)
            ?? stringValue(named: "arguments", in: payload)
            ?? prettyJSON(payload))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let title = (name?.isEmpty == false ? name : nil)
            ?? String(localized: "codexAppServer.event.toolCall", defaultValue: "Tool call")
        return CodexAppServerTranscriptItem(
            role: .event,
            title: title,
            body: CodexAppServerTranscriptPolicy.truncatedBody(body),
            date: date,
            presentation: .toolCall(name: name)
        )
    }

    private static func reasoningSummaryText(from payload: [String: Any]) -> String? {
        let entries = reasoningTextEntries(from: payload["summary"])
        guard !entries.isEmpty else { return nil }
        return normalizedReasoningSummary(entries.joined(separator: "\n\n"))
    }

    private static func reasoningTextEntries(from value: Any?) -> [String] {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let entries = value as? [String] {
            return entries.compactMap { entry in
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        if let entries = value as? [[String: Any]] {
            return entries.compactMap { entry in
                let text = stringValue(named: "text", in: entry)
                    ?? stringValue(named: "content", in: entry)
                    ?? stringValue(named: "summary", in: entry)
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
        }
        return []
    }

    private static func normalizedReasoningSummary(_ text: String) -> String? {
        CodexReasoningSummaryNormalizer.normalized(text)
    }

    private static func messageText(from content: Any?) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let parts = content as? [[String: Any]] else { return nil }
        let text = parts.compactMap { part -> String? in
            if let text = stringValue(named: "text", in: part) {
                return text
            }
            if let text = stringValue(named: "content", in: part) {
                return text
            }
            if let url = stringValue(named: "url", in: part) {
                return url
            }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func functionCallBody(from payload: [String: Any]) -> String {
        guard let arguments = stringValue(named: "arguments", in: payload) else {
            return prettyJSON(payload)
        }
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return arguments
        }

        if let command = stringValue(named: "cmd", in: object) {
            return command
        }
        if let command = stringValue(named: "command", in: object) {
            return command
        }
        if let command = object["command"] as? [String] {
            return command.joined(separator: " ")
        }
        return prettyJSON(object)
    }

    private static func stringValue(named key: String, in object: [String: Any]?) -> String? {
        guard let value = object?[key] else { return nil }
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func dateValue(named key: String, in object: [String: Any]?) -> Date? {
        guard let value = object?[key] else { return nil }
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = TimeInterval(trimmed) {
                return Date(timeIntervalSince1970: seconds)
            }
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: trimmed) {
                return date
            }
            return ISO8601DateFormatter().date(from: trimmed)
        }
        if let value = value as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        return nil
    }

    private static func prettyJSON(_ value: Any?) -> String {
        guard let value else { return "{}" }
        let object: Any
        if JSONSerialization.isValidJSONObject(value) {
            object = value
        } else {
            object = ["value": String(describing: value)]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}
