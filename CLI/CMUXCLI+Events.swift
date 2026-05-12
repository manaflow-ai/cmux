import CoreFoundation
import Darwin
import Foundation

private struct EventStreamLimitReached: Error {}

nonisolated struct CmuxEventsResume: Equatable {
    let afterSequence: Int64?
    let requestedAfterSequence: Int64
    let oldestSequence: Int64
    let latestSequence: Int64
    let nextSequence: Int64
    let gap: Bool
    let gapReason: String?
}

nonisolated struct CmuxEventsClientFrame {
    enum Kind: Equatable {
        case ack(CmuxEventsResume)
        case event(seq: Int64)
        case heartbeat
    }

    let kind: Kind
    let object: [String: Any]

    var eventSequence: Int64? {
        if case let .event(seq) = kind { return seq }
        return nil
    }
}

nonisolated struct CmuxEventsReconnectBackoff {
    private(set) var attempt = 0
    var baseDelay: TimeInterval = 1.0
    var maximumDelay: TimeInterval = 10.0

    mutating func nextDelay() -> TimeInterval {
        let effectiveBaseDelay = max(baseDelay, 0.1)
        let effectiveMaximumDelay = max(maximumDelay, effectiveBaseDelay)
        let exponent = min(attempt, 6)
        let delay = min(effectiveMaximumDelay, effectiveBaseDelay * pow(2.0, Double(exponent)))
        attempt += 1
        return delay
    }

    mutating func reset() {
        attempt = 0
    }
}

nonisolated struct CmuxEventsClientHelper {
    private(set) var receivedAck = false
    private var highWaterSequence: Int64?

    init(afterSequence: Int64?) {
        self.highWaterSequence = afterSequence
    }

    mutating func consume(line: String) throws -> CmuxEventsClientFrame {
        let object = try Self.parseFrameObject(line)
        guard let type = object["type"] as? String, !type.isEmpty else {
            throw CLIError(message: "Invalid event stream frame: missing type")
        }

        guard receivedAck || type == "ack" else {
            throw CLIError(message: "Invalid event stream frame: first frame must be ack")
        }

        switch type {
        case "ack":
            guard !receivedAck else {
                throw CLIError(message: "Invalid event stream frame: duplicate ack")
            }
            let resume = try Self.parseAckResume(object)
            receivedAck = true
            highWaterSequence = resume.gap ? nil : resume.requestedAfterSequence
            return CmuxEventsClientFrame(kind: .ack(resume), object: object)
        case "event":
            let seq = try Self.parseEventSequence(object)
            if let highWaterSequence, seq <= highWaterSequence {
                throw CLIError(
                    message: "Invalid event stream frame: non-increasing seq \(seq) after \(highWaterSequence)"
                )
            }
            highWaterSequence = seq
            return CmuxEventsClientFrame(kind: .event(seq: seq), object: object)
        case "heartbeat":
            return CmuxEventsClientFrame(kind: .heartbeat, object: object)
        default:
            throw CLIError(message: "Invalid event stream frame: unknown type \(type)")
        }
    }

    static func readCursor(from path: String) throws -> Int64? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CLIError(message: "Failed to read events cursor file \(url.path): \(String(describing: error))")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sequence = Int64(trimmed), sequence >= 0 else {
            throw CLIError(message: "Malformed events cursor file \(url.path): expected a non-negative sequence number")
        }
        return sequence
    }

    static func writeCursor(_ seq: Int64, to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(seq)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func parseFrameObject(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw CLIError(message: "Invalid event stream frame: \(line)")
        }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "Invalid event stream frame: \(line)")
            }
            object = parsed
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(message: "Invalid event stream frame: \(line)")
        }
        if let ok = object["ok"] as? Bool, ok == false {
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "event stream error"
            throw CLIError(message: message)
        }
        return object
    }

    private static func parseAckResume(_ object: [String: Any]) throws -> CmuxEventsResume {
        try validateProtocol(object)
        guard let resume = object["resume"] as? [String: Any] else {
            throw CLIError(message: "Invalid event stream ack: missing resume")
        }
        guard let requestedAfterSequence = int64Value(resume["requested_after_seq"]),
              requestedAfterSequence >= 0 else {
            throw CLIError(message: "Invalid event stream ack: resume.requested_after_seq must be numeric")
        }
        guard let oldestSequence = int64Value(resume["oldest_seq"]),
              oldestSequence >= 0 else {
            throw CLIError(message: "Invalid event stream ack: resume.oldest_seq must be numeric")
        }
        guard let latestSequence = int64Value(resume["latest_seq"]),
              latestSequence >= 0 else {
            throw CLIError(message: "Invalid event stream ack: resume.latest_seq must be numeric")
        }
        guard let nextSequence = int64Value(resume["next_seq"]),
              nextSequence >= 0 else {
            throw CLIError(message: "Invalid event stream ack: resume.next_seq must be numeric")
        }
        guard let gap = resume["gap"] as? Bool else {
            throw CLIError(message: "Invalid event stream ack: resume.gap must be boolean")
        }
        let afterSequence = try parseOptionalAckSequence(resume["after_seq"], field: "after_seq")

        return CmuxEventsResume(
            afterSequence: afterSequence,
            requestedAfterSequence: requestedAfterSequence,
            oldestSequence: oldestSequence,
            latestSequence: latestSequence,
            nextSequence: nextSequence,
            gap: gap,
            gapReason: resume["gap_reason"] as? String
        )
    }

    private static func parseEventSequence(_ object: [String: Any]) throws -> Int64 {
        try validateProtocol(object)
        guard let seq = int64Value(object["seq"]), seq >= 0 else {
            throw CLIError(message: "Invalid event stream frame: event missing numeric seq")
        }
        return seq
    }

    private static func validateProtocol(_ object: [String: Any]) throws {
        guard (object["protocol"] as? String) == "cmux-events" else {
            throw CLIError(message: "Invalid event stream frame: protocol must be cmux-events")
        }
        guard int64Value(object["version"]) == 1 else {
            throw CLIError(message: "Invalid event stream frame: version must be 1")
        }
    }

    private static func parseOptionalAckSequence(_ value: Any?, field: String) throws -> Int64? {
        if value == nil || value is NSNull { return nil }
        guard let sequence = int64Value(value), sequence >= 0 else {
            throw CLIError(message: "Invalid event stream ack: resume.\(field) must be numeric")
        }
        return sequence
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let type = String(cString: number.objCType)
            guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type) else { return nil }
            let int64 = number.int64Value
            guard number.compare(NSNumber(value: int64)) == .orderedSame else { return nil }
            return int64
        }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}

extension CMUXCLI {
    private struct EventsCommandOptions {
        var afterSeq: Int64?
        var cursorFile: String?
        var names: [String] = []
        var categories: [String] = []
        var reconnect = false
        var limit: Int?
        var printAck = true
        var printHeartbeats = true
    }

    func runEventsCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        var options = try parseEventsOptions(commandArgs)
        if options.afterSeq == nil, let cursorFile = options.cursorFile {
            options.afterSeq = try CmuxEventsClientHelper.readCursor(from: cursorFile)
        }

        var lastSeq = options.afterSeq
        var emittedEvents = 0
        var backoff = CmuxEventsReconnectBackoff()

        while true {
            let client = SocketClient(path: socketPath)
            var streamHelper = CmuxEventsClientHelper(afterSequence: lastSeq)
            var sawFrame = false
            do {
                try client.connect()
                try authenticateClientIfNeeded(
                    client,
                    explicitPassword: explicitPassword,
                    socketPath: socketPath
                )

                var params: [String: Any] = [
                    "include_heartbeats": true
                ]
                if let lastSeq {
                    params["after_seq"] = NSNumber(value: lastSeq)
                }
                if !options.names.isEmpty {
                    params["names"] = options.names
                }
                if !options.categories.isEmpty {
                    params["categories"] = options.categories
                }

                try client.streamV2(method: "events.stream", params: params) { line in
                    guard !line.isEmpty else { return }
                    let frame = try streamHelper.consume(line: line)
                    sawFrame = true

                    switch frame.kind {
                    case let .ack(resume):
                        if resume.gap {
                            printEventResumeGapGuidance(resume)
                        }
                    case .event, .heartbeat:
                        break
                    }

                    if case .ack = frame.kind, !options.printAck {
                        return
                    }
                    if case .heartbeat = frame.kind, !options.printHeartbeats {
                        return
                    }

                    print(line)
                    fflush(stdout)

                    if let eventSequence = frame.eventSequence {
                        if let cursorFile = options.cursorFile {
                            try CmuxEventsClientHelper.writeCursor(eventSequence, to: cursorFile)
                        }
                        lastSeq = eventSequence
                        emittedEvents += 1
                        if let limit = options.limit, emittedEvents >= limit {
                            throw EventStreamLimitReached()
                        }
                    }
                }
            } catch is EventStreamLimitReached {
                client.close()
                return
            } catch {
                client.close()
                guard options.reconnect, isTransientEventStreamError(error) else {
                    throw error
                }
                if sawFrame {
                    backoff.reset()
                }
                waitBeforeReconnectingEventStream(seconds: backoff.nextDelay())
                continue
            }
        }
    }

    func isTransientEventStreamError(_ error: Error) -> Bool {
        if let cliError = error as? CLIError {
            let message = cliError.message.lowercased()
            let transientMarkers = [
                "socket not found",
                "failed to connect",
                "event stream closed",
                "event stream socket read error",
                "timed out waiting for event stream frame",
                "stream request timed out",
                "failed to write stream request",
                "broken pipe",
                "connection reset",
                "connection refused",
                "errno 32",
                "errno 35",
                "errno 54",
                "errno 57",
                "errno 60",
                "errno 61"
            ]
            return transientMarkers.contains { message.contains($0) }
        }

        let description = String(describing: error).lowercased()
        return description.contains("connection reset")
            || description.contains("connection refused")
            || description.contains("broken pipe")
            || description.contains("timed out")
    }

    private func waitBeforeReconnectingEventStream(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        let deadline = Date(timeIntervalSinceNow: seconds)
        var didFire = false
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            didFire = true
        }
        RunLoop.current.add(timer, forMode: .default)
        while !didFire, RunLoop.current.run(mode: .default, before: deadline) {}
        timer.invalidate()
    }

    private func printEventResumeGapGuidance(_ resume: CmuxEventsResume) {
        let reason = resume.gapReason.map { " (\($0))" } ?? ""
        fputs(
            """
            cmux events: resume gap after seq \(resume.requestedAfterSequence)\(reason). Replayed events are partial; refresh snapshots with commands such as `cmux list-workspaces`, `cmux list-notifications`, or `cmux tree`, then dedupe by event id before continuing.

            """,
            stderr
        )
    }

    private func parseEventsOptions(_ args: [String]) throws -> EventsCommandOptions {
        var options = EventsCommandOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            func requireValue() throws -> String {
                guard index + 1 < args.count else {
                    throw CLIError(message: "\(arg) requires a value")
                }
                index += 1
                return args[index]
            }

            switch arg {
            case "--after", "--after-seq":
                let raw = try requireValue()
                guard let seq = Int64(raw), seq >= 0 else {
                    throw CLIError(message: "\(arg) must be a non-negative integer")
                }
                options.afterSeq = seq
            case "--cursor-file":
                options.cursorFile = try requireValue()
            case "--name":
                options.names.append(try requireValue())
            case "--category":
                options.categories.append(try requireValue())
            case "--reconnect":
                options.reconnect = true
            case "--limit":
                let raw = try requireValue()
                guard let limit = Int(raw), limit > 0 else {
                    throw CLIError(message: "--limit must be greater than 0")
                }
                options.limit = limit
            case "--no-ack":
                options.printAck = false
            case "--no-heartbeat", "--no-heartbeats":
                options.printHeartbeats = false
            default:
                throw CLIError(message: "Unknown events option: \(arg)")
            }
            index += 1
        }
        return options
    }
}
