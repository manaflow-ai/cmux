import Darwin
import CMUXEventsCore
import Foundation

extension TerminalController {
    nonisolated func isEventsStreamRequest(_ line: String) -> Bool {
        CmuxEventStreamRequest.isStreamRequest(line)
    }

    nonisolated func handleEventsStreamRequest(_ line: String, socket: Int32) {
        guard let request = try? CmuxEventStreamRequest(line: line) else {
            _ = writeEventsStreamLine([
                "type": "error",
                "ok": false,
                "error": ["code": "invalid_request", "message": "events.stream requires a JSON object"]
            ], socket: socket)
            return
        }

        let snapshot = CmuxEventBus.shared.subscribe(
            afterSequence: request.afterSequence,
            names: request.names,
            categories: request.categories
        )
        defer { CmuxEventBus.shared.unsubscribe(snapshot.subscription) }

        guard writeEventsStreamLine(snapshot.ack, socket: socket) else { return }
        for event in snapshot.replay {
            guard writeEventsStreamLine(event, socket: socket) else { return }
        }

        while true {
            if let event = snapshot.subscription.next(timeout: CmuxEventBus.defaultHeartbeatIntervalSeconds) {
                guard writeEventsStreamLine(event, socket: socket) else { return }
            } else if snapshot.subscription.isClosed {
                if let reason = snapshot.subscription.closeReason {
                    _ = writeEventsStreamLine([
                        "type": "error",
                        "ok": false,
                        "error": [
                            "code": "slow_consumer",
                            "message": reason,
                            "latest_seq": NSNumber(value: CmuxEventBus.shared.latestSequence)
                        ]
                    ], socket: socket)
                }
                return
            } else if request.includeHeartbeats {
                let heartbeat = CmuxEventBus.shared.heartbeat(subscription: snapshot.subscription)
                guard writeEventsStreamLine(heartbeat, socket: socket) else { return }
            } else if Self.socketPeerClosed(socket) {
                return
            }
        }
    }

    nonisolated func publishSocketEvents(command: String, response: String) {
        CmuxSocketEventMapper.publish(command: command, response: response)
    }

    private nonisolated func writeEventsStreamLine(_ object: [String: Any], socket: Int32) -> Bool {
        guard let line = CmuxEventBus.encodeLine(object) else { return false }
        return Self.writeAllToSocket(Data((line + "\n").utf8), to: socket)
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
