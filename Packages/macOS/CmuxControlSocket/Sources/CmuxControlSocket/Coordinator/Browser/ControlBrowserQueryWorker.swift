internal import Foundation

/// The worker-lane RPC handler for the v2 `browser.find.*` semantic-element
/// locators, lifted byte-faithfully from the former `TerminalController`
/// `v2BrowserFindRole` / `v2BrowserFindText` / `v2BrowserFindLabel` /
/// `v2BrowserFindPlaceholder` / `v2BrowserFindAlt` / `v2BrowserFindTitle` /
/// `v2BrowserFindTestId` / `v2BrowserFindFirst` / `v2BrowserFindLast` /
/// `v2BrowserFindNth` bodies and their `v2BrowserJSCommandOnSocketWorker`
/// dispatch.
///
/// Owns the command dispatch, the param parsing (the byte-faithful twins of
/// `v2String` / `v2Bool` / `v2Int` / `v2BrowserSelector`), the missing-param
/// `invalid_params` branches, and the reply payload shaping (the typed
/// ``JSONValue`` twin of the legacy `[String: Any]` dictionaries; the resulting
/// Foundation object, and therefore the encoded wire bytes, is identical). The
/// app-coupled work (panel resolution, finder-script construction, JavaScript
/// evaluation, result decoding, element-ref allocation) is reached strictly
/// through the ``ControlBrowserQueryReading`` seam. It does no socket I/O and
/// never imports the app target.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: these commands run on the nonisolated
/// socket-worker lane (PR 5778 moved the JS-evaluating `browser.*` methods
/// there, which the `@MainActor` ``ControlCommandCoordinator`` cannot host).
/// ``handle(_:)`` and ``resolveFind(_:)`` are synchronous and run on the calling
/// worker thread, exactly as the legacy `nonisolated` bodies did; the seam's
/// main-actor hops stay inside the conformer.
public struct ControlBrowserQueryWorker: Sendable {
    /// The live browser-query seam. Injected at construction.
    private let reading: any ControlBrowserQueryReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The browser-query seam to read/drive.
    public init(reading: any ControlBrowserQueryReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is a `browser.find.*` worker-lane command,
    /// returning the typed result; returns `nil` for any other method so the
    /// caller can fall through (the remaining JS-evaluating `browser.*` methods
    /// are still served by the legacy app-side dispatcher).
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned method.
    public func handle(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "browser.find.role":
            return findRole(request.params)
        case "browser.find.text":
            return findText(request.params)
        case "browser.find.label":
            return findLabel(request.params)
        case "browser.find.placeholder":
            return findPlaceholder(request.params)
        case "browser.find.alt":
            return findAlt(request.params)
        case "browser.find.title":
            return findTitle(request.params)
        case "browser.find.testid":
            return findTestID(request.params)
        case "browser.find.first":
            return findFirst(request.params)
        case "browser.find.last":
            return findLast(request.params)
        case "browser.find.nth":
            return findNth(request.params)
        default:
            return nil
        }
    }

    // MARK: - find.role / text / label / placeholder / alt / title / testid

    /// `browser.find.role` — `v2BrowserFindRole`.
    private func findRole(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let role = (string(params, "role") ?? string(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing role", data: nil)
        }
        let name = string(params, "name")?.lowercased()
        let exact = bool(params, "exact") ?? false
        return shapeWithScript(
            reading.resolveFind(.role(params: params, role: role, name: name, exact: exact)),
            actionName: "find.role",
            metadata: ["role": .string(role), "name": orNull(name), "exact": .bool(exact)]
        )
    }

    /// `browser.find.text` — `v2BrowserFindText`.
    private func findText(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let text = (string(params, "text") ?? string(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        return shapeWithScript(
            reading.resolveFind(.text(params: params, text: text, exact: exact)),
            actionName: "find.text",
            metadata: ["text": .string(text), "exact": .bool(exact)]
        )
    }

    /// `browser.find.label` — `v2BrowserFindLabel`.
    private func findLabel(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let label = (string(params, "label") ?? string(params, "text") ?? string(params, "value"))?
            .lowercased() else {
            return .err(code: "invalid_params", message: "Missing label", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        return shapeWithScript(
            reading.resolveFind(.label(params: params, label: label, exact: exact)),
            actionName: "find.label",
            metadata: ["label": .string(label), "exact": .bool(exact)]
        )
    }

    /// `browser.find.placeholder` — `v2BrowserFindPlaceholder`.
    private func findPlaceholder(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let placeholder = (string(params, "placeholder") ?? string(params, "text") ?? string(params, "value"))?
            .lowercased() else {
            return .err(code: "invalid_params", message: "Missing placeholder", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        return shapeWithScript(
            reading.resolveFind(.placeholder(params: params, placeholder: placeholder, exact: exact)),
            actionName: "find.placeholder",
            metadata: ["placeholder": .string(placeholder), "exact": .bool(exact)]
        )
    }

    /// `browser.find.alt` — `v2BrowserFindAlt`.
    private func findAlt(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let alt = (string(params, "alt") ?? string(params, "text") ?? string(params, "value"))?
            .lowercased() else {
            return .err(code: "invalid_params", message: "Missing alt text", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        return shapeWithScript(
            reading.resolveFind(.alt(params: params, alt: alt, exact: exact)),
            actionName: "find.alt",
            metadata: ["alt": .string(alt), "exact": .bool(exact)]
        )
    }

    /// `browser.find.title` — `v2BrowserFindTitle`.
    private func findTitle(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let title = (string(params, "title") ?? string(params, "text") ?? string(params, "value"))?
            .lowercased() else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let exact = bool(params, "exact") ?? false
        return shapeWithScript(
            reading.resolveFind(.title(params: params, title: title, exact: exact)),
            actionName: "find.title",
            metadata: ["title": .string(title), "exact": .bool(exact)]
        )
    }

    /// `browser.find.testid` — `v2BrowserFindTestId`.
    private func findTestID(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let testID = string(params, "testid") ?? string(params, "test_id") ?? string(params, "value") else {
            return .err(code: "invalid_params", message: "Missing testid", data: nil)
        }
        return shapeWithScript(
            reading.resolveFind(.testID(params: params, testID: testID)),
            actionName: "find.testid",
            metadata: ["testid": .string(testID)]
        )
    }

    // MARK: - find.first / last / nth

    /// `browser.find.first` — `v2BrowserFindFirst`.
    private func findFirst(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let rawSelector = selector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return shapeSelectorFind(
            reading.resolveFind(.first(params: params, rawSelector: rawSelector)),
            includeIndex: false
        )
    }

    /// `browser.find.last` — `v2BrowserFindLast`.
    private func findLast(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let rawSelector = selector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return shapeSelectorFind(
            reading.resolveFind(.last(params: params, rawSelector: rawSelector)),
            includeIndex: false
        )
    }

    /// `browser.find.nth` — `v2BrowserFindNth`.
    private func findNth(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let rawSelector = selector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        guard let index = int(params, "index") ?? int(params, "nth") else {
            return .err(code: "invalid_params", message: "Missing index", data: nil)
        }
        return shapeSelectorFind(
            reading.resolveFind(.nth(params: params, rawSelector: rawSelector, index: index)),
            includeIndex: true
        )
    }

    // MARK: - Payload shaping

    /// Shapes the success/error payload for the `v2BrowserFindWithScript` family
    /// (`find.role`/`find.text`/…): the base identity, the per-action metadata,
    /// then the optional `tag`/`text` echoes, byte-faithful to the legacy body.
    ///
    /// `metadata` is the worker-built per-action data that the legacy body merged
    /// into the success payload AND attached to the not-found error; the seam
    /// never returns `.notFound(data:)` with a payload for this family (the
    /// metadata lives here), nor `.selectorReferenceNotFound` (no ref is
    /// resolved), but both are handled defensively.
    private func shapeWithScript(
        _ resolution: ControlBrowserFindResolution,
        actionName: String,
        metadata: [String: JSONValue]
    ) -> ControlCallResult {
        switch resolution {
        case .panelUnavailable(let result):
            return result
        case .selectorReferenceNotFound(let rawSelector):
            return .err(
                code: "not_found",
                message: "Element reference not found",
                data: .object(["selector": .string(rawSelector)])
            )
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: .object(["action": .string(actionName)]))
        case .notFound:
            return .err(code: "not_found", message: "Element not found", data: .object(metadata))
        case .found(let element):
            var payload = baseFoundPayload(element)
            payload["action"] = .string(actionName)
            for (key, value) in metadata {
                payload[key] = value
            }
            if let tag = element.tag {
                payload["tag"] = .string(tag)
            }
            if case .string(let text) = element.text {
                payload["text"] = .string(text)
            }
            return .ok(.object(payload))
        }
    }

    /// Shapes the success/error payload for the `find.first`/`find.last`/
    /// `find.nth` family, byte-faithful to the legacy bodies.
    private func shapeSelectorFind(
        _ resolution: ControlBrowserFindResolution,
        includeIndex: Bool
    ) -> ControlCallResult {
        switch resolution {
        case .panelUnavailable(let result):
            return result
        case .selectorReferenceNotFound(let rawSelector):
            return .err(
                code: "not_found",
                message: "Element reference not found",
                data: .object(["selector": .string(rawSelector)])
            )
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .notFound(let data):
            // first/last/nth attach the resolved selector (and, for nth, the
            // index), available only app-side, via the seam's `data`.
            return .err(code: "not_found", message: "Element not found", data: data.map { JSONValue.object($0) })
        case .found(let element):
            var payload = baseFoundPayload(element)
            if includeIndex, case .orNull(let index)? = element.index {
                payload["index"] = index.map { JSONValue.int(Int64($0)) } ?? .null
            }
            if case .orNull(let text) = element.text {
                payload["text"] = text.map { JSONValue.string($0) } ?? .null
            }
            return .ok(.object(payload))
        }
    }

    /// The shared identity payload for a matched element (workspace/surface ids +
    /// refs, the selector, and the `element_ref`/`ref` keys).
    private func baseFoundPayload(_ element: ControlBrowserFoundElement) -> [String: JSONValue] {
        [
            "workspace_id": .string(element.workspaceID.uuidString),
            "workspace_ref": .string(element.workspaceRef),
            "surface_id": .string(element.surfaceID.uuidString),
            "surface_ref": .string(element.surfaceRef),
            "selector": .string(element.selector),
            "element_ref": .string(element.elementRef),
            "ref": .string(element.elementRef),
        ]
    }

    // MARK: - Param parsing (byte-faithful twins of v2String / v2Bool / v2Int)

    /// `v2String`: a trimmed, non-empty JSON string, or `nil` (whitespace-only is
    /// treated as absent).
    private func string(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let raw)? = params[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `v2Bool`: a JSON bool, a number (nonzero is true), or the
    /// `1/true/yes/on` / `0/false/no/off` string set; otherwise `nil`.
    private func bool(_ params: [String: JSONValue], _ key: String) -> Bool? {
        switch params[key] {
        case .bool(let value):
            return value
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// `v2Int`: a JSON int, a number (via `NSNumber.intValue` to clamp/truncate
    /// like the legacy `as? NSNumber` path rather than trap), or a parsable
    /// string.
    private func int(_ params: [String: JSONValue], _ key: String) -> Int? {
        switch params[key] {
        case .int(let value):
            return Int(value)
        case .double(let value):
            return NSNumber(value: value).intValue
        case .bool(let value):
            return NSNumber(value: value).intValue
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    /// `v2BrowserSelector`: the first present, trimmed-non-empty string among
    /// `selector` / `sel` / `element_ref` / `ref`.
    private func selector(_ params: [String: JSONValue]) -> String? {
        string(params, "selector")
            ?? string(params, "sel")
            ?? string(params, "element_ref")
            ?? string(params, "ref")
    }

    /// `v2OrNull` for an optional string param value used in metadata.
    private func orNull(_ value: String?) -> JSONValue {
        value.map { JSONValue.string($0) } ?? .null
    }
}
