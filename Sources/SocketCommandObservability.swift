import CmuxControlSocket
import Darwin
import Foundation
import OSLog

nonisolated struct SocketCommandObservability: Sendable {
    enum ProtocolName: String, Sendable {
        case v1
        case v2
    }

    enum ExecutionLane: String, Sendable {
        case mainActor = "main-actor"
        case socketWorker = "socket-worker"
    }

    enum CompletionThread: String, Sendable {
        case main
        case worker
    }

    enum ResponseStatus: String, Sendable {
        case ok
        case error
        case noResponse = "no-response"
    }

    struct Command: Equatable, Sendable {
        let protocolName: ProtocolName
        let method: String
        let peerPid: pid_t?
        let executionLane: ExecutionLane
    }

    struct Completion: Equatable, Sendable {
        let command: Command
        let status: ResponseStatus
        let durationNanoseconds: UInt64
        let responseByteCount: Int
        let completionThread: CompletionThread

        var durationMilliseconds: Double {
            Double(durationNanoseconds) / 1_000_000
        }

        var formattedMilliseconds: String {
            String(format: "%.2f", durationMilliseconds)
        }
    }

    struct Watchdog {
        fileprivate let task: Task<Void, Never>?

        func cancel() { task?.cancel() }
    }

    struct WatchdogSample: Equatable {
        let url: URL?
        let mainThreadExcerpt: String?
        let errorDescription: String?
    }

    let slowThresholdNanoseconds: UInt64
    let mainActorWatchdogThresholdNanoseconds: UInt64
    let maxWatchdogSampleFiles: Int

    private static let maxSampleExcerptLines = 80
    private static let maxSampleExcerptCharacters = 6_000
    private let watchdogSampleCoordinator = WatchdogSampleCoordinator()
    private let logger: Logger

    init(
        slowThresholdNanoseconds: UInt64 = 100_000_000,
        mainActorWatchdogThresholdNanoseconds: UInt64 = 2_000_000_000,
        maxWatchdogSampleFiles: Int = 20,
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
            category: "socket.command"
        )
    ) {
        self.slowThresholdNanoseconds = slowThresholdNanoseconds
        self.mainActorWatchdogThresholdNanoseconds = mainActorWatchdogThresholdNanoseconds
        self.maxWatchdogSampleFiles = maxWatchdogSampleFiles
        self.logger = logger
    }

    func command(
        for line: String,
        peerPid: pid_t?,
        executionLaneOverride: ExecutionLane? = nil
    ) -> Command {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else {
            let method = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "<empty>"
            let lane = method.lowercased() == "ping" ? ExecutionLane.socketWorker : .mainActor
            return Command(
                protocolName: .v1,
                method: Self.sanitizedToken(method),
                peerPid: peerPid,
                executionLane: executionLaneOverride ?? lane
            )
        }

        guard let method = Self.topLevelJSONMethod(in: trimmed[...]), !method.isEmpty else {
            return Command(
                protocolName: .v2,
                method: "<invalid-json>",
                peerPid: peerPid,
                executionLane: executionLaneOverride ?? .mainActor
            )
        }

        let policy = ControlCommandExecutionPolicy(forMethod: method)
        let lane: ExecutionLane = policy.runsOnSocketWorker ? .socketWorker : .mainActor
        return Command(
            protocolName: .v2,
            method: Self.sanitizedToken(method),
            peerPid: peerPid,
            executionLane: executionLaneOverride ?? lane
        )
    }

    func completion(
        for command: Command,
        startedAt: UInt64,
        finishedAt: UInt64 = DispatchTime.now().uptimeNanoseconds,
        response: String?,
        includeNonSlowFailures: Bool = false,
        completionThread: CompletionThread = Thread.isMainThread ? .main : .worker
    ) -> Completion? {
        let elapsed = finishedAt >= startedAt ? finishedAt - startedAt : 0
        let status = responseStatus(response: response)
        guard elapsed >= slowThresholdNanoseconds || (includeNonSlowFailures && status != .ok) else {
            return nil
        }
        return Completion(
            command: command,
            status: status,
            durationNanoseconds: elapsed,
            responseByteCount: response?.utf8.count ?? 0,
            completionThread: completionThread
        )
    }

    func logCompletionIfNeeded(
        for command: Command,
        startedAt: UInt64,
        response: String?
    ) {
        guard let completion = completion(for: command, startedAt: startedAt, response: response) else {
            return
        }
        logSlowCompletion(completion)
    }

    func startMainActorWatchdog(
        for command: Command,
        startedAt: UInt64,
        thresholdNanoseconds: UInt64? = nil
    ) -> Watchdog {
        guard command.executionLane == .mainActor else {
            return Watchdog(task: nil)
        }

        let thresholdNanoseconds = thresholdNanoseconds ?? mainActorWatchdogThresholdNanoseconds
        let task = Task.detached(priority: .utility) {
            do {
                // swift-blocking-runtime: intentional-watchdog-deadline
                // Intentional deadline: emit release diagnostics if a main-actor socket command stays busy.
                try await Task.sleep(nanoseconds: thresholdNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let finishedAt = DispatchTime.now().uptimeNanoseconds
            let elapsed = finishedAt >= startedAt ? finishedAt - startedAt : 0
            guard await watchdogSampleCoordinator.beginCaptureIfIdle() else {
                // A sample for the same main-actor stall is already in flight.
                // Coalesce onto it instead of spawning another `/usr/bin/sample`:
                // every command queued behind one hang would otherwise cross the
                // threshold together and fan out a burst of samplers, disk writes,
                // and log work against an already-unhealthy app.
                logMainActorWatchdogCoalesced(command: command, elapsedNanoseconds: elapsed)
                return
            }
            let sample = await captureWatchdogSample(for: command)
            await watchdogSampleCoordinator.endCapture()
            guard !Task.isCancelled else { return }
            logMainActorWatchdog(command: command, elapsedNanoseconds: elapsed, sample: sample)
        }

        return Watchdog(task: task)
    }

    func responseStatus(response: String?) -> ResponseStatus {
        guard let response else {
            return .noResponse
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return .error
        }
        if trimmed.hasPrefix("{") {
            let prefix = trimmed.prefix(4096)
            if Self.topLevelJSONResponseStatus(in: prefix) == .error { return .error }
        }
        return .ok
    }

    func mainThreadSampleExcerpt(from sampleText: String) -> String? {
        let lines = sampleText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("com.apple.main-thread") }) else {
            return nil
        }

        var excerpt: [String] = []
        for line in lines[start...] {
            if excerpt.count >= Self.maxSampleExcerptLines {
                break
            }
            if !excerpt.isEmpty,
               line.hasPrefix("    "),
               line.contains(" Thread_") {
                break
            }
            if line.hasPrefix("Total number in stack") ||
                line.hasPrefix("Sort by top of stack") ||
                line.hasPrefix("Binary Images:") {
                break
            }
            excerpt.append(line)
        }

        guard !excerpt.isEmpty else { return nil }
        return Self.truncated(excerpt.joined(separator: "\n"), maxCharacters: Self.maxSampleExcerptCharacters)
    }

    private func logSlowCompletion(_ completion: Completion) {
        let peerPid = completion.command.peerPid.map(String.init) ?? "unknown"
        logger.warning(
            "socket.command.slow proto=\(completion.command.protocolName.rawValue, privacy: .public) method=\(completion.command.method, privacy: .public) lane=\(completion.command.executionLane.rawValue, privacy: .public) completion_thread=\(completion.completionThread.rawValue, privacy: .public) peer_pid=\(peerPid, privacy: .public) status=\(completion.status.rawValue, privacy: .public) ms=\(completion.formattedMilliseconds, privacy: .public) bytes=\(completion.responseByteCount, privacy: .public)"
        )
    }

    private func logMainActorWatchdog(
        command: Command,
        elapsedNanoseconds: UInt64,
        sample: WatchdogSample
    ) {
        let peerPid = command.peerPid.map(String.init) ?? "unknown"
        let elapsedMs = String(format: "%.2f", Double(elapsedNanoseconds) / 1_000_000)
        let samplePath = sample.url?.path ?? "unavailable"
        if let excerpt = sample.mainThreadExcerpt {
            logger.fault(
                "socket.command.main_actor_watchdog method=\(command.method, privacy: .public) proto=\(command.protocolName.rawValue, privacy: .public) peer_pid=\(peerPid, privacy: .public) ms=\(elapsedMs, privacy: .public) sample_path=\(samplePath, privacy: .public) main_thread_sample=\(excerpt, privacy: .public)"
            )
        } else {
            let error = sample.errorDescription ?? "main thread sample excerpt unavailable"
            logger.fault(
                "socket.command.main_actor_watchdog method=\(command.method, privacy: .public) proto=\(command.protocolName.rawValue, privacy: .public) peer_pid=\(peerPid, privacy: .public) ms=\(elapsedMs, privacy: .public) sample_path=\(samplePath, privacy: .public) sample_error=\(error, privacy: .public)"
            )
        }
    }

    private func logMainActorWatchdogCoalesced(command: Command, elapsedNanoseconds: UInt64) {
        let peerPid = command.peerPid.map(String.init) ?? "unknown"
        let elapsedMs = String(format: "%.2f", Double(elapsedNanoseconds) / 1_000_000)
        logger.fault(
            "socket.command.main_actor_watchdog method=\(command.method, privacy: .public) proto=\(command.protocolName.rawValue, privacy: .public) peer_pid=\(peerPid, privacy: .public) ms=\(elapsedMs, privacy: .public) sample=coalesced"
        )
    }

    private static func sanitizedToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).prefix(96)
        return sanitized.isEmpty ? "<empty>" : String(sanitized)
    }

    static func fileNameComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = Self.sanitizedToken(value).unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return cleaned == "<empty>" ? "empty" : String(cleaned.prefix(96))
    }

    static func truncated(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else {
            return value
        }
        return String(value.prefix(maxCharacters)) + "...<truncated>"
    }

    private static func topLevelJSONResponseStatus(in text: Substring) -> ResponseStatus? {
        var index = text.startIndex
        skipJSONWhitespace(in: text, index: &index)
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex {
            skipJSONWhitespace(in: text, index: &index)
            if index >= text.endIndex { return nil }
            if text[index] == "}" { return nil }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            guard text[index] == "\"",
                  let key = scanJSONString(in: text, index: &index) else {
                return nil
            }
            skipJSONWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] == ":" else { return nil }
            index = text.index(after: index)
            skipJSONWhitespace(in: text, index: &index)

            if key == "error" {
                return .error
            }
            if key == "ok" {
                if text[index...].hasPrefix("false") {
                    return .error
                }
                if text[index...].hasPrefix("true") {
                    return .ok
                }
            }
            guard skipJSONValue(in: text, index: &index) else {
                return nil
            }
        }
        return nil
    }

    private static func topLevelJSONMethod(in text: Substring) -> String? {
        var index = text.startIndex
        skipJSONWhitespace(in: text, index: &index)
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex {
            skipJSONWhitespace(in: text, index: &index)
            if index >= text.endIndex { return nil }
            if text[index] == "}" { return nil }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            guard text[index] == "\"",
                  let key = scanJSONString(in: text, index: &index) else {
                return nil
            }
            skipJSONWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] == ":" else { return nil }
            index = text.index(after: index)
            skipJSONWhitespace(in: text, index: &index)

            if key == "method" {
                guard index < text.endIndex,
                      text[index] == "\"",
                      let value = scanJSONString(in: text, index: &index) else {
                    return nil
                }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard skipJSONValue(in: text, index: &index) else {
                return nil
            }
        }
        return nil
    }

    private static func scanJSONString(in text: Substring, index: inout String.Index) -> String? {
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var result = ""
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if char == "\\" {
                guard index < text.endIndex else { return nil }
                let escape = text[index]
                index = text.index(after: index)
                switch escape {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    // Decode \uXXXX to its scalar. Surrogate halves and malformed
                    // sequences yield nil and are dropped; the sanitizer guards the label.
                    if let scalar = Self.scanJSONUnicodeEscape(in: text, index: &index) {
                        result.unicodeScalars.append(scalar)
                    }
                default:
                    // Unknown escape: keep the literal character (lenient parsing).
                    result.append(escape)
                }
                continue
            }
            if char == "\"" {
                return result
            }
            result.append(char)
        }
        return nil
    }

    private static func scanJSONUnicodeEscape(in text: Substring, index: inout String.Index) -> Unicode.Scalar? {
        var value: UInt32 = 0
        var count = 0
        while count < 4 {
            guard index < text.endIndex, let digit = text[index].hexDigitValue else { return nil }
            value = value * 16 + UInt32(digit)
            index = text.index(after: index)
            count += 1
        }
        return Unicode.Scalar(value)
    }

    private static func skipJSONValue(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        switch text[index] {
        case "\"":
            return scanJSONString(in: text, index: &index) != nil
        case "{", "[":
            return skipJSONContainer(in: text, index: &index)
        default:
            while index < text.endIndex {
                switch text[index] {
                case ",", "}":
                    return true
                default:
                    index = text.index(after: index)
                }
            }
            return true
        }
    }

    private static func skipJSONContainer(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        let opener = text[index]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 1
        index = text.index(after: index)
        var isInString = false
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    isInString = false
                }
                continue
            }
            if char == "\"" {
                isInString = true
            } else if char == opener {
                depth += 1
            } else if char == closer {
                depth -= 1
                if depth == 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func skipJSONWhitespace(in text: Substring, index: inout String.Index) {
        while index < text.endIndex {
            switch text[index] {
            case " ", "\t", "\n", "\r":
                index = text.index(after: index)
            default:
                return
            }
        }
    }
}
