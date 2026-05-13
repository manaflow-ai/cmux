import CMUXSocketProtocol
import Darwin
import Foundation

extension TerminalController {
    nonisolated func isEventsStreamRequest(_ line: String) -> Bool {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return false
        }
        return method == "events.stream"
    }

    nonisolated func handleEventsStreamRequest(
        _ line: String,
        socket: Int32,
        writeInitialResponse: Bool = true
    ) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if writeInitialResponse {
                if CMUXSocketProtocol.malformedRequestUsesJSONRPC(line) {
                    let response = CMUXSocketProtocol.malformedRequestError(
                        command: line,
                        code: "invalid_request",
                        message: "events.stream requires a JSON object"
                    )
                    _ = Self.writeAllToSocket(Data((response + "\n").utf8), to: socket)
                } else {
                    _ = writeEventsStreamLine([
                        "type": "error",
                        "ok": false,
                        "error": ["code": "invalid_request", "message": "events.stream requires a JSON object"]
                    ], socket: socket)
                }
            }
            return
        }

        let usesJSONRPC = CMUXSocketProtocol.usesJSONRPC(object)
        let requestId: Any? = object["id"]
        let params: [String: Any]
        do {
            params = try CMUXSocketProtocol.paramsObject(in: object)
        } catch {
            if writeInitialResponse {
                if usesJSONRPC {
                    let response = v2Error(
                        id: requestId,
                        jsonRPC: true,
                        code: "invalid_params",
                        message: "params must be a JSON object"
                    )
                    _ = Self.writeAllToSocket(Data((response + "\n").utf8), to: socket)
                } else {
                    _ = writeEventsStreamLine([
                        "type": "error",
                        "ok": false,
                        "error": ["code": "invalid_params", "message": "params must be a JSON object"]
                    ], socket: socket)
                }
            }
            return
        }
        let afterSequence = CmuxEventBus.int64(params["after_seq"] ?? params["after"])
        let names = Self.stringSet(params["names"] ?? params["name"])
        let categories = Self.stringSet(params["categories"] ?? params["category"])
        let includeHeartbeats = Self.boolParam(params["include_heartbeats"] ?? params["include_heartbeat"]) ?? true

        let snapshot = CmuxEventBus.shared.subscribe(
            afterSequence: afterSequence,
            names: names,
            categories: categories
        )
        defer { CmuxEventBus.shared.unsubscribe(snapshot.subscription) }

        if writeInitialResponse {
            guard writeEventsStreamLine(snapshot.ack, socket: socket, jsonRPC: usesJSONRPC, responseId: requestId) else { return }
        }
        for event in snapshot.replay {
            guard writeEventsStreamLine(event, socket: socket, jsonRPC: usesJSONRPC) else { return }
        }

        while true {
            if let event = snapshot.subscription.next(timeout: CmuxEventBus.defaultHeartbeatIntervalSeconds) {
                guard writeEventsStreamLine(event, socket: socket, jsonRPC: usesJSONRPC) else { return }
            } else if snapshot.subscription.isClosed {
                if let reason = snapshot.subscription.closeReason {
                    var errorFrame: [String: Any] = [
                        "type": "error",
                        "error": [
                            "code": "slow_consumer",
                            "message": reason,
                            "latest_seq": NSNumber(value: CmuxEventBus.shared.latestSequence)
                        ]
                    ]
                    if !usesJSONRPC {
                        errorFrame["ok"] = false
                    }
                    _ = writeEventsStreamLine(errorFrame, socket: socket, jsonRPC: usesJSONRPC)
                }
                return
            } else if includeHeartbeats {
                let heartbeat = CmuxEventBus.shared.heartbeat(subscription: snapshot.subscription)
                guard writeEventsStreamLine(heartbeat, socket: socket, jsonRPC: usesJSONRPC) else { return }
            } else if Self.socketPeerClosed(socket) {
                return
            }
        }
    }

    nonisolated func publishSocketEvents(command: String, response: String) {
        CmuxSocketEventMapper.publish(command: command, response: response)
    }

    private nonisolated func writeEventsStreamLine(
        _ object: [String: Any],
        socket: Int32,
        jsonRPC: Bool = false,
        responseId: Any? = nil
    ) -> Bool {
        let frame = jsonRPC ? CMUXSocketProtocol.eventStreamFrame(object, responseId: responseId) : object
        guard let line = CmuxEventBus.encodeLine(frame) else { return false }
        return Self.writeAllToSocket(Data((line + "\n").utf8), to: socket)
    }

    private nonisolated static func stringSet(_ value: Any?) -> Set<String> {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let values = value as? [String] {
            return Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        if let values = value as? [Any] {
            return Set(values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return []
    }

    private nonisolated static func boolParam(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if number.compare(NSNumber(value: 0)) == .orderedSame { return false }
            if number.compare(NSNumber(value: 1)) == .orderedSame { return true }
            return nil
        }
        guard let string = value as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    private nonisolated static func socketPeerClosed(_ socket: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if result == 0 {
            return true
        }
        if result > 0 {
            return false
        }
        let errorCode = errno
        return errorCode != EAGAIN && errorCode != EWOULDBLOCK && errorCode != EINTR
    }
}
