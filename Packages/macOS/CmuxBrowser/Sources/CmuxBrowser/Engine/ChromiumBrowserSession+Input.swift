@preconcurrency public import Foundation

extension ChromiumBrowserSession {
    /// Stops the active page load without terminating the Chromium child.
    ///
    /// - Throws: A CDP transport or command error.
    public func stopLoading() async throws {
        if let owlRuntime {
            let pendingIntent = owlNavigationIntent
            let wasLoading = isLoading
            let stoppedURL: URL?
            let stoppedDocumentEpoch: Double?
            do {
                let raw = try owlRuntime.evaluate("(window.stop(), {href: String(location.href || ''), documentEpoch: Number(performance.timeOrigin || 0)})")
                if let data = raw.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data),
                   let object = object as? [String: Any],
                   let href = object["href"] as? String {
                    stoppedURL = URL(string: href)
                    stoppedDocumentEpoch = CDPValue(any: object["documentEpoch"]).doubleValue
                } else {
                    stoppedURL = nil
                    stoppedDocumentEpoch = nil
                }
            } catch {
                failOwlNavigation()
                throw error
            }
            owlNavigationReadinessTask?.cancel()
            owlNavigationReadinessTask = nil
            owlNavigationIntent = nil
            owlNavigationSawLoadingEvent = false
            owlNavigationBaselineDocumentEpoch = nil
            owlCurrentDocumentEpoch = stoppedDocumentEpoch
            if let stoppedURL {
                if let pendingIntent {
                    switch pendingIntent {
                    case .destination, .rendererDestination:
                        if !Self.matches(url: currentURL, target: stoppedURL) {
                            owlHistory?.commitDestination(stoppedURL)
                        }
                    case .back(let expectedURL) where Self.matches(url: stoppedURL, target: expectedURL):
                        owlHistory?.commitTraversal(to: stoppedURL, offset: -1)
                    case .forward(let expectedURL) where Self.matches(url: stoppedURL, target: expectedURL):
                        owlHistory?.commitTraversal(to: stoppedURL, offset: 1)
                    case .reload:
                        owlHistory?.commitReload()
                    case .back, .forward, .destination, .rendererDestination:
                        break
                    }
                    syncOwlHistorySnapshot()
                }
                currentURL = stoppedURL
            }
            isLoading = false
            if pendingIntent != nil || wasLoading {
                navigationRevision &+= 1
            }
            publish()
            return
        }
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
        if let owlRuntime {
            try owlRuntime.resize(width: width, height: height, scale: deviceScaleFactor)
            return
        }
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
        if let owlRuntime {
            return try await evaluateOwlJavaScript(
                script,
                runtime: owlRuntime,
                awaitPromise: awaitPromise
            )
        }
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

    private func evaluateOwlJavaScript(
        _ script: String,
        runtime: OwlFreshRuntime,
        awaitPromise: Bool
    ) async throws -> CDPValue {
        if !awaitPromise {
            return Self.owlValue(from: try runtime.evaluate(script))
        }

        let token = "__cmux_owl_eval_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let quotedToken = "\"\(token)\""
        let isExpression: Bool
        do {
            // Parse in a short-circuited expression inside an async arrow
            // without executing the caller's source. The async context keeps
            // top-level `await` valid in the probe while page CSP never has to
            // permit eval/new Function.
            _ = try runtime.evaluate("(async () => 0 && (\(script)))")
            isExpression = true
        } catch {
            isExpression = false
        }

        let body: String
        if isExpression {
            body = "return await (\n\(script)\n);"
        } else {
            body = Self.owlStatementBody(for: script)
        }
        let startScript = """
        (() => {
          const key = \(quotedToken);
          globalThis[key] = { state: "pending" };
          try {
            const value = (async () => {
              \(body)
            })();
            Promise.resolve(value).then(
              resolved => { globalThis[key] = { state: "fulfilled", value: resolved }; },
              error => { globalThis[key] = { state: "rejected", error: String(error) }; }
            );
          } catch (error) {
            globalThis[key] = { state: "rejected", error: String(error) };
          }
          return globalThis[key];
        })()
        """
        _ = try runtime.evaluate(startScript)
        defer {
            _ = try? runtime.evaluate("delete globalThis[\(quotedToken)]")
        }

        for _ in 0..<750 {
            try Task.checkCancellation()
            let raw = try runtime.evaluate("globalThis[\(quotedToken)] || { state: 'pending' }")
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = parsed as? [String: Any],
                  let state = object["state"] as? String else {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            switch state {
            case "fulfilled":
                return CDPValue(any: object["value"])
            case "rejected":
                throw CDPError.commandFailed(
                    object["error"] as? String ?? ChromiumBrowserDiagnostic.javaScriptEvaluationFailed.message
                )
            default:
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw ChromiumBrowserDiagnostic.javascriptTimedOut
    }

    /// Returns a direct async-function body for a statement program. JavaScript
    /// has no syntax for reading a program's implicit completion value without
    /// eval; when the final top-level statement is an expression, move that
    /// expression into an explicit return so the common multi-statement form
    /// keeps Runtime.evaluate's completion-value behavior without dynamic code
    /// generation.
    static func owlStatementBody(for source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "return undefined;" }

        var candidateEnd = trimmed.endIndex
        var hadTrailingSemicolon = false
        while candidateEnd > trimmed.startIndex {
            let previous = trimmed.index(before: candidateEnd)
            guard trimmed[previous] == ";" else { break }
            hadTrailingSemicolon = true
            candidateEnd = previous
            while candidateEnd > trimmed.startIndex,
                  trimmed[trimmed.index(before: candidateEnd)].isWhitespace {
                candidateEnd = trimmed.index(before: candidateEnd)
            }
        }
        let candidate = String(trimmed[..<candidateEnd])
        guard !candidate.isEmpty else { return "return undefined;" }
        guard let semicolon = owlTopLevelSemicolon(in: candidate) else {
            return hadTrailingSemicolon && !owlStartsWithStatementKeyword(candidate)
                ? "return await (\(candidate));"
                : candidate
        }
        let suffixStart = candidate.index(after: semicolon)
        let suffix = candidate[suffixStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty,
              !owlStartsWithStatementKeyword(suffix) else {
            return candidate
        }
        let prefix = candidate[..<suffixStart]
        return String(prefix) + "\nreturn await (" + suffix + ");"
    }

    private static func owlStartsWithStatementKeyword(_ source: String) -> Bool {
        let keywords = [
            "break", "case", "class", "const", "continue", "debugger", "default", "do", "else",
            "finally", "for", "function", "if", "let", "return", "switch", "throw", "try", "var", "while",
        ]
        for keyword in keywords where source.hasPrefix(keyword) {
            let boundary = source.index(source.startIndex, offsetBy: keyword.count)
            if boundary == source.endIndex || source[boundary].isWhitespace || source[boundary] == "(" || source[boundary] == "{" || source[boundary] == ";" {
                return true
            }
        }
        return false
    }

    private static func owlTopLevelSemicolon(in source: String) -> String.Index? {
        var parentheses = 0
        var brackets = 0
        var braces = 0
        var quote: Character?
        var escaped = false
        var lineComment = false
        var blockComment = false
        var last: String.Index?
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            let nextIndex = source.index(after: index)
            let next = nextIndex < source.endIndex ? source[nextIndex] : "\0"

            if lineComment {
                if character == "\n" { lineComment = false }
                index = nextIndex
                continue
            }
            if blockComment {
                if character == "*" && next == "/" {
                    blockComment = false
                    index = source.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                continue
            }
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index = nextIndex
                continue
            }
            if character == "/" && next == "/" {
                lineComment = true
                index = source.index(after: nextIndex)
                continue
            }
            if character == "/" && next == "*" {
                blockComment = true
                index = source.index(after: nextIndex)
                continue
            }
            switch character {
            case "\"", "'", "`":
                quote = character
            case "(": parentheses += 1
            case ")": parentheses = max(0, parentheses - 1)
            case "[": brackets += 1
            case "]": brackets = max(0, brackets - 1)
            case "{": braces += 1
            case "}": braces = max(0, braces - 1)
            case ";" where parentheses == 0 && brackets == 0 && braces == 0:
                last = index
            default:
                break
            }
            index = nextIndex
        }
        return last
    }

    private static func owlValue(from raw: String) -> CDPValue {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .string(raw)
        }
        return CDPValue(any: object)
    }

    /// Captures the current Chromium viewport as PNG bytes.
    ///
    /// - Returns: Encoded PNG data.
    /// - Throws: A CDP transport error or malformed screenshot response.
    public func screenshotPNG() async throws -> Data {
        if let owlRuntime {
            return try owlRuntime.screenshotPNG()
        }
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
        if let owlRuntime {
            let kind = OwlFreshMouseKind(cdpType: type).rawValue
            let buttonValue: UInt32 = button == "right" ? 2 : (button == "middle" ? 1 : 0)
            try owlRuntime.mouse(kind: kind, x: x, y: y, button: buttonValue, clickCount: UInt32(max(1, clickCount)), deltaX: deltaX, deltaY: deltaY, modifiers: 0)
            return
        }
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
        if let owlRuntime {
            // OWL exposes routed keyboard events rather than a CDP
            // Input.insertText command. A text-bearing key pair follows the
            // same native path as dispatchKey and produces a char event for
            // IME/paste text without requiring a CDP connection.
            try owlRuntime.key(down: true, keyCode: 0, text: text, modifiers: 0)
            try owlRuntime.key(down: false, keyCode: 0, text: nil, modifiers: 0)
            return
        }
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
        if let owlRuntime {
            try owlRuntime.key(down: type != "keyUp", keyCode: UInt32(max(0, windowsVirtualKeyCode)), text: text, modifiers: UInt32(max(0, modifiers)))
            return
        }
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
