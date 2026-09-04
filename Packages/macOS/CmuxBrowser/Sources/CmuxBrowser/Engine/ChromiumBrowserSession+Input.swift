@preconcurrency public import Foundation

extension ChromiumBrowserSession {
    /// Stops the active page load without terminating the Chromium child.
    ///
    /// - Throws: A CDP transport or command error.
    public func stopLoading() async throws {
        _ = try await send(method: "Page.stopLoading")
    }

    /// Updates the CSS viewport used by the headless renderer. Keeping this
    /// operation on the session actor makes resize events race-free with CDP
    /// navigation and screencast frame acknowledgements.
    ///
    /// - Parameters:
    ///   - width: CSS viewport width, clamped to at least one point.
    ///   - height: CSS viewport height, clamped to at least one point.
    ///   - deviceScaleFactor: Backing scale reported to page content.
    /// - Throws: A CDP transport or command error.
    public func setViewport(
        width: Int,
        height: Int,
        deviceScaleFactor: Double = 1
    ) async throws {
        _ = try await send(
            method: "Emulation.setDeviceMetricsOverride",
            parameters: .object([
                "width": .number(Double(max(1, width))),
                "height": .number(Double(max(1, height))),
                "deviceScaleFactor": .number(max(0.1, deviceScaleFactor)),
                "mobile": .bool(false),
            ])
        )
    }

    /// Evaluates JavaScript in the active page and returns its value by copy.
    ///
    /// - Parameters:
    ///   - script: JavaScript program accepted by `Runtime.evaluate`.
    ///   - awaitPromise: Whether Chromium should await a returned promise.
    /// - Returns: JSON-compatible result, or `.null` for no value.
    /// - Throws: A CDP transport, command, or JavaScript evaluation error.
    public func evaluateJavaScript(_ script: String, awaitPromise: Bool = true) async throws -> CDPValue {
        let parameters: CDPValue = .object([
            "expression": .string(script),
            "returnByValue": .bool(true),
            "awaitPromise": .bool(awaitPromise),
            "userGesture": .bool(true),
        ])
        let value = try await send(method: "Runtime.evaluate", parameters: parameters)
        guard case .object(let object) = value else { return value }
        if let exception = object["exceptionDetails"] {
            throw CDPError.commandFailed(Self.exceptionMessage(exception))
        }
        guard let result = object["result"], case .object(let remoteObject) = result else {
            return .null
        }
        return remoteObject["value"] ?? .null
    }

    /// Captures the current Chromium viewport as PNG bytes.
    ///
    /// - Returns: Encoded PNG data.
    /// - Throws: A CDP transport error or malformed screenshot response.
    public func screenshotPNG() async throws -> Data {
        let value = try await send(
            method: "Page.captureScreenshot",
            parameters: .object(["format": .string("png")])
        )
        guard case .object(let object) = value,
              let encoded = object["data"]?.stringValue,
              let data = Data(base64Encoded: encoded) else {
            throw CDPError.protocolError(ChromiumBrowserDiagnostic.noScreenshot.message)
        }
        return data
    }

    /// Dispatches one native-style pointer event through CDP.
    ///
    /// - Parameters:
    ///   - type: CDP mouse event type.
    ///   - x: Horizontal CSS coordinate.
    ///   - y: Vertical CSS coordinate.
    ///   - button: CDP button name.
    ///   - clickCount: Click count for press/release events.
    ///   - deltaX: Horizontal wheel delta.
    ///   - deltaY: Vertical wheel delta.
    /// - Throws: A CDP transport or command error.
    public func dispatchMouse(
        type: String,
        x: Double,
        y: Double,
        button: String = "none",
        clickCount: Int = 1,
        deltaX: Double = 0,
        deltaY: Double = 0
    ) async throws {
        var values: [String: CDPValue] = [
            "type": .string(type),
            "x": .number(x),
            "y": .number(y),
            "button": .string(button),
            "clickCount": .number(Double(max(1, clickCount))),
        ]
        if type == "mouseWheel" {
            values["deltaX"] = .number(deltaX)
            values["deltaY"] = .number(deltaY)
        }
        _ = try await send(
            method: "Input.dispatchMouseEvent",
            parameters: .object(values)
        )
    }

    /// Inserts text through Chromium's input method path.
    ///
    /// - Parameter text: Text to insert at the current page selection.
    /// - Throws: A CDP transport or command error.
    public func insertText(_ text: String) async throws {
        _ = try await send(
            method: "Input.insertText",
            parameters: .object(["text": .string(text)])
        )
    }

    /// Dispatches one keyboard event through CDP.
    ///
    /// - Parameters:
    ///   - type: CDP key event type.
    ///   - key: DOM key value.
    ///   - code: DOM physical-key code.
    ///   - text: Optional text produced by a key-down event.
    ///   - modifiers: CDP modifier bitmask.
    ///   - windowsVirtualKeyCode: Chromium virtual key code used for legacy
    ///     `KeyboardEvent.keyCode` and `which` values.
    /// - Throws: A CDP transport or command error.
    public func dispatchKey(
        type: String,
        key: String,
        code: String,
        text: String? = nil,
        modifiers: Int = 0,
        windowsVirtualKeyCode: Int = 0
    ) async throws {
        var parameters: [String: CDPValue] = [
            "type": .string(type),
            "key": .string(key),
            "code": .string(code),
            "modifiers": .number(Double(max(0, modifiers))),
            "windowsVirtualKeyCode": .number(Double(max(0, windowsVirtualKeyCode))),
        ]
        if let text {
            parameters["text"] = .string(text)
            parameters["unmodifiedText"] = .string(text)
        }
        _ = try await send(method: "Input.dispatchKeyEvent", parameters: .object(parameters))
    }

    /// Sends a raw CDP command for an automation feature not represented by
    /// the engine-neutral client protocol (for example Network cookie APIs).
    /// The command still uses this pane's isolated page connection.
    ///
    /// - Parameters:
    ///   - method: CDP method name.
    ///   - parameters: Optional typed JSON parameters.
    /// - Returns: Typed JSON command result.
    /// - Throws: A CDP transport or command error.
    public func sendCommand(
        method: String,
        parameters: CDPValue? = nil
    ) async throws -> CDPValue {
        try await send(method: method, parameters: parameters)
    }

    /// Returns the advertised endpoint when external debugging is enabled.
    ///
    /// - Returns: The loopback endpoint, or `nil` when external CDP is disabled.
    public func externallyVisibleEndpoint() -> BrowserCDPEndpoint? {
        snapshot().externallyVisibleEndpoint
    }

    private static func exceptionMessage(_ value: CDPValue) -> String {
        guard case .object(let object) = value else { return ChromiumBrowserDiagnostic.javaScriptEvaluationFailed.message }
        if let description = object["text"]?.stringValue { return description }
        if case .object(let details)? = object["exception"],
           let description = details["description"]?.stringValue {
            return description
        }
        return ChromiumBrowserDiagnostic.javaScriptEvaluationFailed.message
    }
}
