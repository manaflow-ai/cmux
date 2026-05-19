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
        var scope: String?
        var window: String?
        var workspace: String?
        var surface: String?
        var pane: String?
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
                try applyEventScopeOptions(
                    options: options,
                    params: &params,
                    socketPath: socketPath,
                    explicitPassword: explicitPassword
                )

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
            case "--scope":
                options.scope = try canonicalEventScope(try requireValue())
            case "--global":
                options.scope = "global"
            case "--window":
                options.window = try requireValue()
            case "--workspace":
                options.workspace = try requireValue()
            case "--surface", "--tab", "--panel":
                options.surface = canonicalEventSurfaceHandle(try requireValue())
            case "--pane":
                options.pane = try requireValue()
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

    private func applyEventScopeOptions(
        options: EventsCommandOptions,
        params: inout [String: Any],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let effectiveScope = try effectiveEventScope(options)
        let hasSelector = options.window != nil || options.workspace != nil ||
            options.surface != nil || options.pane != nil
        if effectiveScope == "global", hasSelector {
            throw CLIError(message: "--scope global cannot be combined with --window, --workspace, --surface, or --pane")
        }
        params["scope"] = effectiveScope

        let caller = eventCallerContextFromEnvironment()
        if let caller {
            params["caller"] = caller
        }

        guard hasSelector else {
            return
        }

        let resolver = SocketClient(path: socketPath)
        do {
            try resolver.connect()
            try authenticateClientIfNeeded(
                resolver,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )

            let windowHandle = try normalizeWindowHandle(options.window, client: resolver)
            if let windowHandle {
                params["window_id"] = windowHandle
            }

            let requiresWorkspaceContext = options.workspace != nil ||
                eventScopeSelectorNeedsWorkspaceContext(options.surface) ||
                eventScopeSelectorNeedsWorkspaceContext(options.pane)
            let callerWorkspaceHandle = caller?["workspace_id"] as? String
            let workspaceOption = options.workspace ??
                (windowHandle == nil && requiresWorkspaceContext ? callerWorkspaceHandle : nil)
            let workspaceHandle = try normalizeWorkspaceHandle(
                workspaceOption,
                client: resolver,
                windowHandle: windowHandle,
                allowCurrent: requiresWorkspaceContext
            )
            if let workspaceHandle {
                params["workspace_id"] = workspaceHandle
            }

            let surfaceHandle = try normalizeSurfaceHandle(
                options.surface,
                client: resolver,
                workspaceHandle: workspaceHandle
            )
            if let surfaceHandle {
                params["surface_id"] = surfaceHandle
            }

            let paneHandle = try normalizePaneHandle(
                options.pane,
                client: resolver,
                workspaceHandle: workspaceHandle
            )
            if let paneHandle {
                params["pane_id"] = paneHandle
            }
            resolver.close()
        } catch {
            resolver.close()
            throw error
        }
    }

    private func effectiveEventScope(_ options: EventsCommandOptions) throws -> String {
        if let scope = options.scope {
            return scope
        }
        if options.pane != nil { return "pane" }
        if options.surface != nil { return "surface" }
        if options.workspace != nil { return "workspace" }
        if options.window != nil { return "window" }
        return "global"
    }

    private func canonicalEventScope(_ raw: String) throws -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-") {
        case "global", "all":
            return "global"
        case "window", "current-window":
            return "window"
        case "workspace", "tab":
            return "workspace"
        case "surface", "panel":
            return "surface"
        case "pane":
            return "pane"
        default:
            let message = String(
                format: String(
                    localized: "cli.error.eventsUnknownScope",
                    defaultValue: "Unknown events scope: %@. Use one of: global, window, workspace, surface, pane. Run `cmux events --help` for more info."
                ),
                raw
            )
            throw CLIError(message: message)
        }
    }

    private func eventScopeSelectorNeedsWorkspaceContext(_ raw: String?) -> Bool {
        guard let trimmed = normalizedEventEnvironmentValue(raw) else { return false }
        if UUID(uuidString: trimmed) != nil { return false }
        if eventScopeSelectorIsHandleRef(trimmed) { return false }
        return Int(trimmed) != nil
    }

    private func eventScopeSelectorIsHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "pane", "surface"].contains(kind) else { return false }
        return Int(String(pieces[1])) != nil
    }

    private func canonicalEventSurfaceHandle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              ["tab", "panel"].contains(String(pieces[0]).lowercased()),
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "surface:\(ordinal)"
    }

    private func eventCallerContextFromEnvironment() -> [String: Any]? {
        let environment = ProcessInfo.processInfo.environment
        var caller: [String: Any] = [:]
        if let workspaceId = normalizedEventEnvironmentValue(environment["CMUX_WORKSPACE_ID"]) {
            caller["workspace_id"] = workspaceId
        }
        if let surfaceId = normalizedEventEnvironmentValue(environment["CMUX_SURFACE_ID"]) {
            caller["surface_id"] = surfaceId
            caller["tab_id"] = surfaceId
        }
        if let paneId = normalizedEventEnvironmentValue(environment["CMUX_PANE_ID"]) {
            caller["pane_id"] = paneId
        }
        return caller.isEmpty ? nil : caller
    }

    private func normalizedEventEnvironmentValue(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
