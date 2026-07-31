import Darwin
import Foundation

private struct EventStreamLimitReached: Error {}
private struct EventStreamSnapshotCaptured: Error {}

extension CMUXCLI {
    private struct EventsCommandOptions {
        var afterSeq: Int64?
        var cursorFile: String?
        var names: [String] = []
        var categories: [String] = []
        var reconnect = false
        var limit: Int?
        var timeout: TimeInterval?
        var snapshotOnly = false
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
            options.afterSeq = try readEventCursor(from: cursorFile)
        }

        var lastSeq = options.afterSeq
        var emittedEvents = 0
        let deadline = options.timeout.map { Date.now.addingTimeInterval($0) }

        while true {
            if let deadline, Date.now >= deadline {
                throw CLIError(message: Self.eventsTimedOutMessage)
            }
            let client = SocketClient(path: socketPath)
            // Capture an existing dead inode before connect so a refused
            // connection waits for that exact socket to be replaced instead
            // of treating its mere presence as a wake signal.
            var connectedSocketIdentity = SocketClient.socketFilesystemIdentity(
                at: socketPath
            )
            do {
                if let deadline {
                    try client.connect(deadline: deadline)
                } else {
                    try client.connect()
                }
                connectedSocketIdentity = SocketClient.socketFilesystemIdentity(
                    at: socketPath
                ) ?? connectedSocketIdentity
                try authenticateClientIfNeeded(
                    client,
                    explicitPassword: explicitPassword,
                    socketPath: socketPath,
                    responseTimeout: deadline?.timeIntervalSinceNow,
                    deadline: deadline
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

                try client.streamV2(
                    method: "events.stream",
                    params: params,
                    deadline: deadline
                ) { line in
                    guard !line.isEmpty else { return }
                    let frame = try parseEventStreamFrame(line)
                    let type = frame["type"] as? String ?? ""

                    let eventSequence: Int64?
                    if type == "event" {
                        guard let seq = int64Value(frame["seq"]) else {
                            throw CLIError(message: "Invalid event stream frame: event missing numeric seq")
                        }
                        eventSequence = seq
                    } else {
                        eventSequence = nil
                    }

                    let shouldPrint =
                        (type != "ack" || options.printAck)
                        && (type != "heartbeat" || options.printHeartbeats)
                    if shouldPrint {
                        print(line)
                        fflush(stdout)
                    }

                    if type == "ack", options.snapshotOnly {
                        throw EventStreamSnapshotCaptured()
                    }

                    if let eventSequence {
                        if let cursorFile = options.cursorFile {
                            try writeEventCursor(eventSequence, to: cursorFile)
                        }
                        lastSeq = eventSequence
                        emittedEvents += 1
                        if let limit = options.limit, emittedEvents >= limit {
                            throw EventStreamLimitReached()
                        }
                    }
                }
            } catch is EventStreamSnapshotCaptured {
                client.close()
                return
            } catch is EventStreamLimitReached {
                client.close()
                return
            } catch {
                client.close()
                if let deadline, Date.now >= deadline {
                    throw CLIError(message: Self.eventsTimedOutMessage)
                }
                guard options.reconnect, isTransientEventStreamError(error) else {
                    throw error
                }
                let remaining = deadline?.timeIntervalSinceNow ?? 1
                guard remaining > 0 else {
                    throw CLIError(message: Self.eventsTimedOutMessage)
                }
                waitBeforeReconnectingEventStream(
                    socketPath: socketPath,
                    replacing: connectedSocketIdentity,
                    maximumDelay: remaining
                )
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

    func waitBeforeReconnectingEventStream(
        socketPath: String,
        replacing connectedSocketIdentity: String?,
        maximumDelay: TimeInterval = 1
    ) {
        let delay = min(1, max(0, maximumDelay))
        guard delay > 0 else { return }
        // Wait on the socket directory rather than pumping a RunLoop timer.
        // A tagged app restart or socket replacement wakes the retry
        // immediately; the deadline remains only a quiet-period ceiling.
        SocketClient.waitForSocketReplacement(
            at: socketPath,
            replacing: connectedSocketIdentity,
            timeout: delay
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
            case "--timeout":
                let raw = try requireValue()
                guard let timeout = TimeInterval(raw),
                      timeout.isFinite,
                      timeout > 0 else {
                    throw CLIError(message: String(
                        localized: "cli.events.error.timeoutPositive",
                        defaultValue: "--timeout must be greater than 0"
                    ))
                }
                options.timeout = timeout
            case "--snapshot":
                options.snapshotOnly = true
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

    private static var eventsTimedOutMessage: String {
        String(
            localized: "cli.events.error.timedOut",
            defaultValue: "Timed out waiting for a matching event"
        )
    }

    static var eventsCommandUsage: String {
        String(localized: "cli.events.usage", defaultValue: """
        Usage: cmux events [options]

        Stream cmux events as newline-delimited JSON.

        Options:
          --after <seq>          Replay retained events after this sequence
          --cursor-file <path>   Read the starting sequence from a file and update it after each event
          --name <event>         Filter by event name, repeatable
          --category <name>      Filter by category, repeatable
          --reconnect            Reconnect forever and resume from the last received sequence
          --limit <n>            Exit after printing n event frames
          --timeout <seconds>    Exit unsuccessfully if no matching event arrives before the deadline
          --snapshot             Print the subscription snapshot and exit
          --no-ack               Do not print the subscription ack frame
          --no-heartbeat         Do not print heartbeat frames

        Examples:
          cmux events --category notification
          cmux events --cursor-file ~/.cache/cmux/events.seq --reconnect
          cmux events --after 42 --name feed.item.received
        """)
    }

    private func parseEventStreamFrame(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: "Invalid event stream frame: \(line)")
        }
        if let ok = object["ok"] as? Bool, ok == false {
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "event stream error"
            throw CLIError(message: message)
        }
        return object
    }

    private func readEventCursor(from path: String) throws -> Int64? {
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

    private func writeEventCursor(_ seq: Int64, to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(seq)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func int64Value(_ value: Any?) -> Int64? {
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
