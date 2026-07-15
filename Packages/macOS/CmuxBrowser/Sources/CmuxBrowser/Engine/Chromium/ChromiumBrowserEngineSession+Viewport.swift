import Foundation

extension ChromiumBrowserEngineSession {
    func handleViewportMessage(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "resize":
            viewportWidth = max(1, payload["width"] as? Int ?? viewportWidth)
            viewportHeight = max(1, payload["height"] as? Int ?? viewportHeight)
            deviceScaleFactor = max(1, payload["scale"] as? Double ?? deviceScaleFactor)
            updateDeviceMetrics()
        case "mouse":
            dispatchMouse(payload)
        case "key":
            dispatchKey(payload)
        default:
            break
        }
    }

    func sendDeviceMetrics(connection: CDPConnection, sessionID: String) async throws {
        _ = try await connection.send(
            method: "Emulation.setDeviceMetricsOverride",
            parameters: [
                "width": .number(Double(viewportWidth)),
                "height": .number(Double(viewportHeight)),
                "deviceScaleFactor": .number(deviceScaleFactor),
                "mobile": .bool(false),
            ],
            sessionID: sessionID
        )
    }

    private func updateDeviceMetrics() {
        guard let connection, let cdpSessionID else { return }
        Task { try? await sendDeviceMetrics(connection: connection, sessionID: cdpSessionID) }
    }

    private func dispatchMouse(_ payload: [String: Any]) {
        guard let connection, let cdpSessionID,
              let event = payload["event"] as? String else { return }
        let buttonIndex = payload["button"] as? Int ?? -1
        let button = [0: "left", 1: "middle", 2: "right"][buttonIndex] ?? "none"
        var parameters: [String: CDPJSONValue] = [
            "type": .string(event),
            "x": .number(payload["x"] as? Double ?? 0),
            "y": .number(payload["y"] as? Double ?? 0),
            "button": .string(button),
            "modifiers": .number(Double(payload["modifiers"] as? Int ?? 0)),
            "clickCount": .number(Double(payload["clickCount"] as? Int ?? 0)),
        ]
        if event == "mouseWheel" {
            parameters["deltaX"] = .number(payload["deltaX"] as? Double ?? 0)
            parameters["deltaY"] = .number(payload["deltaY"] as? Double ?? 0)
        }
        Task {
            try? await connection.send(
                method: "Input.dispatchMouseEvent",
                parameters: parameters,
                sessionID: cdpSessionID
            )
        }
    }

    private func dispatchKey(_ payload: [String: Any]) {
        guard let connection, let cdpSessionID,
              let event = payload["event"] as? String else { return }
        let parameters: [String: CDPJSONValue] = [
            "type": .string(event),
            "key": .string(payload["key"] as? String ?? ""),
            "code": .string(payload["code"] as? String ?? ""),
            "text": .string(payload["text"] as? String ?? ""),
            "modifiers": .number(Double(payload["modifiers"] as? Int ?? 0)),
        ]
        Task {
            try? await connection.send(
                method: "Input.dispatchKeyEvent",
                parameters: parameters,
                sessionID: cdpSessionID
            )
        }
    }
}
