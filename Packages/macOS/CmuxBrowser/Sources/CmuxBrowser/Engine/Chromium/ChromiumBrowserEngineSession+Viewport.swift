import Foundation

struct ChromiumViewportInputCommand: Equatable {
    enum CoalescingKind: Equatable {
        case mouseMove
        case mouseWheel
    }

    let method: String
    var parameters: [String: CDPJSONValue]
    let coalescingKind: CoalescingKind?

    static func mouse(parameters: [String: CDPJSONValue]) -> Self {
        let coalescingKind: CoalescingKind? = switch parameters["type"] {
        case .string("mouseMoved"):
            .mouseMove
        case .string("mouseWheel"):
            .mouseWheel
        default:
            nil
        }
        return Self(
            method: "Input.dispatchMouseEvent",
            parameters: parameters,
            coalescingKind: coalescingKind
        )
    }

    static func key(parameters: [String: CDPJSONValue]) -> Self {
        Self(
            method: "Input.dispatchKeyEvent",
            parameters: parameters,
            coalescingKind: nil
        )
    }

    func coalescing(with newer: Self) -> Self {
        guard coalescingKind == .mouseWheel, newer.coalescingKind == .mouseWheel else {
            return newer
        }
        var parameters = newer.parameters
        parameters["deltaX"] = .number(number(for: "deltaX") + newer.number(for: "deltaX"))
        parameters["deltaY"] = .number(number(for: "deltaY") + newer.number(for: "deltaY"))
        return Self(
            method: newer.method,
            parameters: parameters,
            coalescingKind: newer.coalescingKind
        )
    }

    private func number(for key: String) -> Double {
        guard case .number(let value) = parameters[key] else { return 0 }
        return value
    }
}

struct ChromiumViewportInputQueue {
    static let maximumPendingCommands = 64

    private(set) var commands: [ChromiumViewportInputCommand] = []

    var count: Int { commands.count }

    mutating func enqueue(_ command: ChromiumViewportInputCommand) {
        if let coalescingKind = command.coalescingKind {
            let currentOrderingSegmentStart = commands.lastIndex(where: {
                $0.coalescingKind == nil
            }).map { $0 + 1 } ?? commands.startIndex
            if let existingIndex = commands[currentOrderingSegmentStart...].firstIndex(where: {
                $0.coalescingKind == coalescingKind
            }) {
                commands[existingIndex] = commands[existingIndex].coalescing(with: command)
                return
            }
        }

        if commands.count == Self.maximumPendingCommands {
            guard let coalescibleIndex = commands.firstIndex(where: {
                $0.coalescingKind != nil
            }) else {
                return
            }
            commands.remove(at: coalescibleIndex)
        }
        commands.append(command)
    }

    mutating func popFirst() -> ChromiumViewportInputCommand? {
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }

    mutating func removeAll() {
        commands.removeAll(keepingCapacity: true)
    }
}

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
        enqueueViewportInput(.mouse(parameters: parameters))
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
        enqueueViewportInput(.key(parameters: parameters))
    }

    private func enqueueViewportInput(_ command: ChromiumViewportInputCommand) {
        viewportInputQueue.enqueue(command)
        guard viewportInputTask == nil else { return }
        viewportInputTask = Task { [weak self] in
            await self?.drainViewportInput()
        }
    }

    private func drainViewportInput() async {
        defer { viewportInputTask = nil }
        while !Task.isCancelled, let command = viewportInputQueue.popFirst() {
            guard let connection, let cdpSessionID else {
                viewportInputQueue.removeAll()
                return
            }
            do {
                _ = try await connection.send(
                    method: command.method,
                    parameters: command.parameters,
                    sessionID: cdpSessionID
                )
            } catch {
                viewportInputQueue.removeAll()
                return
            }
        }
    }
}
