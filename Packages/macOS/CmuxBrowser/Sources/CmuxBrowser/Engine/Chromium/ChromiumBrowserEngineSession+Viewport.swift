import Foundation

struct ChromiumViewportInputCommand: Equatable {
    enum CoalescingKind: Equatable {
        case mouseMove
        case mouseWheel
    }

    enum GestureTransition: Equatable {
        case began(String)
        case ended(String)
    }

    let method: String
    var parameters: [String: CDPJSONValue]
    let coalescingKind: CoalescingKind?

    var gestureTransition: GestureTransition? {
        switch (method, parameters["type"], parameters["code"], parameters["button"]) {
        case ("Input.dispatchKeyEvent", .string("keyDown"), .string(let code), _):
            return .began("key:\(code)")
        case ("Input.dispatchKeyEvent", .string("keyUp"), .string(let code), _):
            return .ended("key:\(code)")
        case ("Input.dispatchMouseEvent", .string("mousePressed"), _, .string(let button)):
            return .began("mouse:\(button)")
        case ("Input.dispatchMouseEvent", .string("mouseReleased"), _, .string(let button)):
            return .ended("mouse:\(button)")
        default:
            return nil
        }
    }

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

    static func text(parameters: [String: CDPJSONValue]) -> Self {
        Self(
            method: "Input.insertText",
            parameters: parameters,
            coalescingKind: nil
        )
    }

    static func composition(parameters: [String: CDPJSONValue]) -> Self {
        Self(
            method: "Input.imeSetComposition",
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

    /// Enqueues input while retaining the newest complete gestures under pressure.
    ///
    /// - Returns: `false` only when the queue contains no fully closed gesture that
    ///   can be discarded without separating a press from its release.
    @discardableResult
    mutating func enqueue(_ command: ChromiumViewportInputCommand) -> Bool {
        if let coalescingKind = command.coalescingKind {
            let currentOrderingSegmentStart = commands.lastIndex(where: {
                $0.coalescingKind == nil
            }).map { $0 + 1 } ?? commands.startIndex
            if let existingIndex = commands[currentOrderingSegmentStart...].firstIndex(where: {
                $0.coalescingKind == coalescingKind
            }) {
                commands[existingIndex] = commands[existingIndex].coalescing(with: command)
                return true
            }
        }

        if commands.count == Self.maximumPendingCommands {
            if let coalescibleIndex = commands.firstIndex(where: {
                $0.coalescingKind != nil
            }) {
                commands.remove(at: coalescibleIndex)
            } else if !discardOldestCompleteGesture() {
                return false
            }
        }
        commands.append(command)
        return true
    }

    mutating func popFirst() -> ChromiumViewportInputCommand? {
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }

    mutating func removeAll() {
        commands.removeAll(keepingCapacity: true)
    }

    private mutating func discardOldestCompleteGesture() -> Bool {
        for startIndex in commands.indices {
            guard case .began(let firstGesture)? = commands[startIndex].gestureTransition else {
                continue
            }
            var activeGestures: Set<String> = [firstGesture]
            var endIndex = commands.index(after: startIndex)
            var isBalanced = true
            while endIndex < commands.endIndex {
                switch commands[endIndex].gestureTransition {
                case .began(let gesture):
                    activeGestures.insert(gesture)
                case .ended(let gesture):
                    if activeGestures.contains(gesture) {
                        activeGestures.remove(gesture)
                    } else {
                        isBalanced = false
                    }
                case nil:
                    break
                }
                guard isBalanced else { break }
                if activeGestures.isEmpty {
                    commands.removeSubrange(startIndex...endIndex)
                    return true
                }
                endIndex = commands.index(after: endIndex)
            }
        }
        return false
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

    private func dispatchText(_ payload: [String: Any]) {
        guard let text = payload["text"] as? String, !text.isEmpty else { return }
        enqueueViewportInput(.text(parameters: ["text": .string(text)]))
    }

    private func dispatchComposition(_ payload: [String: Any]) {
        guard let text = payload["text"] as? String else { return }
        let selectionStart = max(0, payload["selectionStart"] as? Int ?? text.utf16.count)
        let selectionEnd = max(selectionStart, payload["selectionEnd"] as? Int ?? selectionStart)
        enqueueViewportInput(.composition(parameters: [
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
