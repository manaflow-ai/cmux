import CoreFoundation
import Darwin
import Foundation

private struct EventStreamLimitReached: Error {}

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
            options.afterSeq = try readEventCursor(from: cursorFile)
        }

        var lastSeq = options.afterSeq
        var emittedEvents = 0

        while true {
            let client = SocketClient(path: socketPath)
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

                    if type == "ack", !options.printAck {
                        return
                    }
                    if type == "heartbeat", !options.printHeartbeats {
                        return
                    }

                    print(line)
                    fflush(stdout)

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
            } catch is EventStreamLimitReached {
                client.close()
                return
            } catch {
                client.close()
                guard options.reconnect, isTransientEventStreamError(error) else {
                    throw error
                }
                waitBeforeReconnectingEventStream()
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

    func waitBeforeReconnectingEventStream() {
        let deadline = Date(timeIntervalSinceNow: 1.0)
        var didFire = false
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            didFire = true
        }
        RunLoop.current.add(timer, forMode: .default)
        while !didFire, RunLoop.current.run(mode: .default, before: deadline) {}
        timer.invalidate()
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
