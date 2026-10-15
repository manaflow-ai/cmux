public import Foundation

/// Encodes automation requests as Chrome DevTools protocol parameters and
/// decodes their results. Pure, so every engine rule is unit-testable
/// without Chromium.
public struct ChromiumDevToolsCodec: Sendable {
    public init() {}

    // MARK: - Runtime.evaluate

    /// The expression `Runtime.evaluate` runs for `script` in `form`.
    ///
    /// An async function body is wrapped in an async arrow invocation, which
    /// is what WebKit's `callAsyncJavaScript` does with the same source.
    public func expression(for script: String, form: BrowserAutomationScriptForm) -> String {
        switch form {
        case .expression:
            return script
        case .asyncFunctionBody:
            return "(async () => {\n\(script)\n})()"
        }
    }

    /// `Runtime.evaluate` parameters.
    /// - Parameters:
    ///   - script: the script source.
    ///   - form: how `script` is shaped.
    ///   - contextID: the isolated world's execution context, nil for the page world.
    public func evaluateParams(
        script: String,
        form: BrowserAutomationScriptForm,
        contextID: Int?
    ) -> [String: any Sendable] {
        var params: [String: any Sendable] = [
            "expression": expression(for: script, form: form),
            "returnByValue": true,
            "awaitPromise": true,
            // Automation must work on hidden and background pages; user
            // gesture lets scripted clicks open popups the way WebKit's do.
            "userGesture": true,
        ]
        if let contextID {
            params["contextId"] = contextID
        }
        return params
    }

    /// Decodes a `Runtime.evaluate` result into the Foundation value WebKit
    /// would have returned, nil for `undefined`.
    public func evaluationValue(fromJSON json: String) throws(BrowserAutomationPageError) -> Any? {
        let object = try parseObject(json)
        if let details = object["exceptionDetails"] as? [String: Any] {
            throw .javaScript(exceptionMessage(details))
        }
        guard let remote = object["result"] as? [String: Any] else {
            throw .malformedResponse("Runtime.evaluate result has no result object")
        }
        return remoteObjectValue(remote)
    }

    /// The value of a by-value `Runtime.RemoteObject`.
    func remoteObjectValue(_ remote: [String: Any]) -> Any? {
        let type = remote["type"] as? String
        if type == "undefined" { return nil }
        if let unserializable = remote["unserializableValue"] as? String {
            switch unserializable {
            case "NaN": return NSNumber(value: Double.nan)
            case "Infinity": return NSNumber(value: Double.infinity)
            case "-Infinity": return NSNumber(value: -Double.infinity)
            case "-0": return NSNumber(value: -0.0)
            default:
                // BigInt literals ("12n") have no Foundation number form.
                return unserializable
            }
        }
        if remote.keys.contains("value") {
            return remote["value"] ?? NSNull()
        }
        if (remote["subtype"] as? String) == "null" { return NSNull() }
        // Functions and symbols have no by-value form; WebKit reports nil too.
        return nil
    }

    /// The exception text of `exceptionDetails`, first line of the error's
    /// description (the stack is dropped, as WebKit drops it).
    func exceptionMessage(_ details: [String: Any]) -> String {
        if let exception = details["exception"] as? [String: Any] {
            if let description = exception["description"] as? String, !description.isEmpty {
                let firstLine = description.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
                return String(firstLine ?? Substring(description))
            }
            if let value = exception["value"] {
                return "Uncaught \(value)"
            }
        }
        if let text = details["text"] as? String, !text.isEmpty {
            return text
        }
        return String(
            localized: "browser.automation.error.javaScriptException",
            defaultValue: "A JavaScript exception occurred",
            bundle: .module
        )
    }

    // MARK: - Isolated world

    /// The main frame id of a `Page.getFrameTree` result.
    public func mainFrameID(fromJSON json: String) throws(BrowserAutomationPageError) -> String {
        let object = try parseObject(json)
        guard let tree = object["frameTree"] as? [String: Any],
              let frame = tree["frame"] as? [String: Any],
              let id = frame["id"] as? String, !id.isEmpty else {
            throw .malformedResponse("Page.getFrameTree has no main frame")
        }
        return id
    }

    /// The execution context id of a `Page.createIsolatedWorld` result.
    public func executionContextID(fromJSON json: String) throws(BrowserAutomationPageError) -> Int {
        let object = try parseObject(json)
        guard let id = (object["executionContextId"] as? NSNumber)?.intValue else {
            throw .malformedResponse("Page.createIsolatedWorld has no executionContextId")
        }
        return id
    }

    /// True when a protocol error says an execution context went away (the
    /// page navigated after the isolated world was created).
    public func isStaleContextError(_ error: BrowserAutomationPageError) -> Bool {
        guard case .engine(let message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("cannot find context") || lower.contains("execution context was destroyed")
    }

    // MARK: - Page.captureScreenshot

    /// `Page.captureScreenshot` parameters for a PNG of the viewport.
    public var screenshotParams: [String: any Sendable] {
        ["format": "png", "fromSurface": true, "captureBeyondViewport": false]
    }

    /// PNG bytes of a `Page.captureScreenshot` result.
    public func screenshotPNG(fromJSON json: String) throws(BrowserAutomationPageError) -> Data {
        let object = try parseObject(json)
        guard let base64 = object["data"] as? String,
              let data = Data(base64Encoded: base64), !data.isEmpty else {
            throw .malformedResponse("Page.captureScreenshot returned no image data")
        }
        return data
    }

    // MARK: - Cookies

    /// The cookies of a `Network.getAllCookies` result as `HTTPCookie`s.
    ///
    /// A cookie whose domain has no leading dot is host-only, which is also
    /// how Foundation represents host-only cookies, so `browser cookies get`
    /// reports `hostOnly` the same way on both engines.
    public func cookies(fromJSON json: String) throws(BrowserAutomationPageError) -> [HTTPCookie] {
        let object = try parseObject(json)
        guard let list = object["cookies"] as? [[String: Any]] else {
            throw .malformedResponse("Network.getAllCookies has no cookies")
        }
        return list.compactMap(cookie(fromProtocol:))
    }

    func cookie(fromProtocol entry: [String: Any]) -> HTTPCookie? {
        guard let name = entry["name"] as? String,
              let domain = entry["domain"] as? String, !domain.isEmpty else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: entry["value"] as? String ?? "",
            .domain: domain,
            .path: entry["path"] as? String ?? "/",
        ]
        if entry["secure"] as? Bool == true {
            properties[.secure] = "TRUE"
        }
        if entry["httpOnly"] as? Bool == true {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        let session = entry["session"] as? Bool ?? true
        if !session, let expires = (entry["expires"] as? NSNumber)?.doubleValue, expires > 0 {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        } else {
            properties[.discard] = "TRUE"
        }
        if let sameSite = entry["sameSite"] as? String {
            properties[.sameSitePolicy] = sameSite.lowercased()
        }
        return HTTPCookie(properties: properties)
    }

    /// `Network.setCookie` parameters for `cookie`.
    ///
    /// A host-only cookie (domain without a leading dot) is set through a
    /// `url` and no `domain`, which is how the protocol makes a host-only
    /// cookie; a domain cookie keeps its dotted domain.
    public func setCookieParams(_ cookie: HTTPCookie) -> [String: any Sendable] {
        var params: [String: any Sendable] = [
            "name": cookie.name,
            "value": cookie.value,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
        ]
        if cookie.domain.hasPrefix(".") {
            params["domain"] = cookie.domain
        } else {
            let scheme = cookie.isSecure ? "https" : "http"
            params["url"] = "\(scheme)://\(cookie.domain)\(cookie.path.hasPrefix("/") ? cookie.path : "/" + cookie.path)"
        }
        if let expires = cookie.expiresDate {
            params["expires"] = expires.timeIntervalSince1970
        }
        if let sameSite = cookie.sameSitePolicy {
            switch sameSite {
            case .sameSiteLax: params["sameSite"] = "Lax"
            case .sameSiteStrict: params["sameSite"] = "Strict"
            default: break
            }
        }
        return params
    }

    /// Whether a `Network.setCookie` result reports success. Older protocol
    /// versions answer `{"success": false}` instead of an error.
    public func setCookieSucceeded(fromJSON json: String) -> Bool {
        guard let object = try? parseObject(json) else { return false }
        return (object["success"] as? Bool) ?? true
    }

    /// `Network.deleteCookies` parameters for exactly `cookie`.
    public func deleteCookieParams(_ cookie: HTTPCookie) -> [String: any Sendable] {
        ["name": cookie.name, "domain": cookie.domain, "path": cookie.path]
    }

    // MARK: - Input.dispatchKeyEvent

    /// The `Input.dispatchKeyEvent` calls for one automation key action.
    ///
    /// `press` sends `keyDown` (with `text`, so the key types) and `keyUp`;
    /// a non-text key sends `rawKeyDown` so Chromium does not insert a
    /// character. Modifier keys report their own modifier bit while held,
    /// matching what a real keyboard reports.
    public func keyEventParams(
        _ event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction,
        modifiers: BrowserKeyboardNativeModifiers
    ) -> [[String: any Sendable]] {
        let native = event.nativeKey
        var held = modifiers.union(native?.modifiers ?? [])
        held.remove(.numericPad)
        let text = typedText(for: event, modifiers: held)
        var base: [String: any Sendable] = [
            "key": event.key,
            "code": event.code,
            "windowsVirtualKeyCode": event.legacyKeyCode,
            "location": event.location,
        ]
        if let keyCode = native?.keyCode {
            base["nativeVirtualKeyCode"] = Int(keyCode)
        }
        if event.location == 3 {
            base["isKeypad"] = true
        }

        func params(type: String, modifiers: BrowserKeyboardNativeModifiers, withText: Bool) -> [String: any Sendable] {
            var params = base
            params["type"] = type
            params["modifiers"] = protocolModifiers(modifiers)
            if withText, let text {
                params["text"] = text
                params["unmodifiedText"] = text
            }
            return params
        }

        let modifierKey = native?.modifierKey
        let downModifiers = modifierKey.map { held.union($0) } ?? held
        let upModifiers = modifierKey.map { held.subtracting($0) } ?? held
        let downType = text == nil ? "rawKeyDown" : "keyDown"
        switch action {
        case .press:
            return [
                params(type: downType, modifiers: downModifiers, withText: true),
                params(type: "keyUp", modifiers: upModifiers, withText: false),
            ]
        case .keyDown:
            return [params(type: downType, modifiers: downModifiers, withText: true)]
        case .keyUp:
            return [params(type: "keyUp", modifiers: upModifiers, withText: false)]
        }
    }

    /// The text a key inserts, nil for keys that insert none (named keys, or
    /// a chord with Command/Control which is a shortcut, not typing).
    func typedText(for event: BrowserKeyboardEvent, modifiers: BrowserKeyboardNativeModifiers) -> String? {
        if !modifiers.intersection([.command, .control]).isEmpty { return nil }
        switch event.key {
        case "Enter": return "\r"
        case "Tab": return "\t"
        default: break
        }
        guard event.key.count == 1 else { return nil }
        guard let scalar = event.key.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        return event.key
    }

    /// The protocol's modifier bitmask: Alt=1, Ctrl=2, Meta=4, Shift=8.
    func protocolModifiers(_ modifiers: BrowserKeyboardNativeModifiers) -> Int {
        var mask = 0
        if modifiers.contains(.option) { mask |= 1 }
        if modifiers.contains(.control) { mask |= 2 }
        if modifiers.contains(.command) { mask |= 4 }
        if modifiers.contains(.shift) { mask |= 8 }
        return mask
    }

    // MARK: - Emulation

    /// `Emulation.setDeviceMetricsOverride` parameters, nil to clear
    /// (`Emulation.clearDeviceMetricsOverride`).
    public func viewportOverrideParams(width: Int?, height: Int?) -> [String: any Sendable]? {
        guard let width, let height else { return nil }
        return [
            "width": max(0, width),
            "height": max(0, height),
            "deviceScaleFactor": 0,
            "mobile": false,
        ]
    }

    // MARK: - JSON

    /// The JSON text of a parameters object, for transports that send text.
    public func jsonText(_ params: [String: any Sendable]) -> String {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    func parseObject(_ json: String) throws(BrowserAutomationPageError) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            throw .malformedResponse(String(json.prefix(120)))
        }
        return object
    }
}
