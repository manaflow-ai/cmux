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
        case "text":
            dispatchText(payload)
        case "composition":
            dispatchComposition(payload)
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
        deviceMetricsPending = true
        guard deviceMetricsTask == nil else { return }
        deviceMetricsTask = Task { [weak self] in
            await self?.drainDeviceMetrics()
        }
    }

    private func drainDeviceMetrics() async {
        defer { deviceMetricsTask = nil }
        while deviceMetricsPending, !Task.isCancelled {
            deviceMetricsPending = false
            guard let connection, let cdpSessionID else { return }
            _ = try? await sendDeviceMetrics(connection: connection, sessionID: cdpSessionID)
        }
    }

    private func dispatchMouse(_ payload: [String: Any]) {
        guard let event = payload["event"] as? String else { return }
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
        enqueueViewportInput(ChromiumViewportInputCommand(mouseParameters: parameters))
    }

    private func dispatchKey(_ payload: [String: Any]) {
        guard let event = payload["event"] as? String else { return }
        let parameters: [String: CDPJSONValue] = [
            "type": .string(event),
            "key": .string(payload["key"] as? String ?? ""),
            "code": .string(payload["code"] as? String ?? ""),
            "text": .string(payload["text"] as? String ?? ""),
            "modifiers": .number(Double(payload["modifiers"] as? Int ?? 0)),
        ]
        enqueueViewportInput(ChromiumViewportInputCommand(keyParameters: parameters))
    }

    private func dispatchText(_ payload: [String: Any]) {
        guard let text = payload["text"] as? String, !text.isEmpty else { return }
        enqueueViewportInput(ChromiumViewportInputCommand(textParameters: ["text": .string(text)]))
    }

    private func dispatchComposition(_ payload: [String: Any]) {
        guard let text = payload["text"] as? String else { return }
        let selectionStart = max(0, payload["selectionStart"] as? Int ?? text.utf16.count)
        let selectionEnd = max(selectionStart, payload["selectionEnd"] as? Int ?? selectionStart)
        enqueueViewportInput(ChromiumViewportInputCommand(compositionParameters: [
            "text": .string(text),
            "selectionStart": .number(Double(selectionStart)),
            "selectionEnd": .number(Double(selectionEnd)),
        ]))
    }

    private func enqueueViewportInput(_ command: ChromiumViewportInputCommand) {
        guard viewportInputQueue.enqueue(command) else { return }
        startViewportInputDrainingIfNeeded()
    }

    func startViewportInputDrainingIfNeeded() {
        guard !viewportInputFailed,
              viewportInputQueue.count > 0,
              connection != nil,
              cdpSessionID != nil else {
            return
        }
        guard viewportInputTask == nil else { return }
        viewportInputTask = Task { [weak self] in
            await self?.drainViewportInput()
        }
    }

    private func drainViewportInput() async {
        defer { viewportInputTask = nil }
        while !Task.isCancelled, let command = viewportInputQueue.popFirst() {
            guard let connection, let cdpSessionID else {
                return
            }
            do {
                try await connection.sendUnacknowledged(
                    method: command.method,
                    parameters: command.parameters,
                    sessionID: cdpSessionID
                )
            } catch {
                failViewportInput()
                return
            }
        }
    }
}
