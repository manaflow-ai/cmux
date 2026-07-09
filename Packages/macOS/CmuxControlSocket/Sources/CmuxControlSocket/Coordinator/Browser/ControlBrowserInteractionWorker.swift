internal import Foundation

/// The worker-lane RPC handler for the v2 `browser.*` interaction commands
/// (`browser.click` / `dblclick` / `hover` / `focus` / `type` / `fill` / `press` /
/// `keydown` / `keyup` / `check` / `uncheck` / `select` / `scroll` /
/// `scroll_into_view` / `highlight`), lifted byte-faithfully from the former
/// `TerminalController` `v2BrowserClick` / `v2BrowserType` / `v2BrowserPress` / …
/// bodies and their `v2BrowserJSCommandOnSocketWorker` dispatch.
///
/// Owns the command dispatch, the leaf-param parsing (the byte-faithful twins of
/// `v2String` / `v2RawString` / `v2Int`), the missing-param `invalid_params`
/// branches (`text` for `type`, `text`/`value` for `fill`, `value`/`text` for
/// `select`, `key` for `press`/`keydown`/`keyup`), and the panel-action reply
/// payload shaping for `press`/`keydown`/`keyup`/`scroll` (the typed ``JSONValue``
/// twin of the legacy `[String: Any]` dictionaries; the resulting Foundation
/// object, and therefore the encoded wire bytes, is identical). The app-coupled
/// work (panel resolution, the per-action `BrowserControlService` script builders,
/// the shared `v2BrowserSelectorAction` retry loop, the JavaScript evaluation, the
/// not-found diagnostics, the element-ref resolution, the `--snapshot-after` walk)
/// is reached strictly through the ``ControlBrowserInteractionReading`` seam. It
/// does no socket I/O and never imports the app target.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: these commands run on the nonisolated
/// socket-worker lane (PR 5778 moved the JS-evaluating `browser.*` methods there,
/// which the `@MainActor` ``ControlCommandCoordinator`` cannot host).
/// ``handle(_:)`` is synchronous and runs on the calling worker thread, exactly as
/// the legacy `nonisolated` bodies did; the seam's main-actor hops stay inside the
/// conformer.
public struct ControlBrowserInteractionWorker: Sendable {
    /// The live browser-interaction seam. Injected at construction.
    private let reading: any ControlBrowserInteractionReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The browser-interaction seam to read/drive.
    public init(reading: any ControlBrowserInteractionReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is a `browser.*` interaction worker-lane
    /// command, returning the typed result; returns `nil` for any other method so
    /// the caller can fall through (the remaining JS-evaluating `browser.*` methods
    /// are still served by the legacy app-side dispatcher).
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned method.
    public func handle(_ request: ControlRequest) -> ControlCallResult? {
        let params = request.params
        switch request.method {
        case "browser.click":
            return shape(reading.resolveInteraction(.click(params: params)))
        case "browser.dblclick":
            return shape(reading.resolveInteraction(.doubleClick(params: params)))
        case "browser.hover":
            return shape(reading.resolveInteraction(.hover(params: params)))
        case "browser.focus":
            return shape(reading.resolveInteraction(.focusElement(params: params)))
        case "browser.type":
            guard let text = string(params, "text") else {
                return .err(code: "invalid_params", message: "Missing text", data: nil)
            }
            return shape(reading.resolveInteraction(.type(params: params, text: text)))
        case "browser.fill":
            // `fill` must allow empty strings so callers can clear existing input
            // values (the legacy `v2RawString` path, not the trimmed `v2String`).
            guard let text = rawString(params, "text") ?? rawString(params, "value") else {
                return .err(code: "invalid_params", message: "Missing text/value", data: nil)
            }
            return shape(reading.resolveInteraction(.fill(params: params, text: text)))
        case "browser.check":
            return shape(reading.resolveInteraction(.check(params: params, checked: true)))
        case "browser.uncheck":
            return shape(reading.resolveInteraction(.check(params: params, checked: false)))
        case "browser.select":
            guard let value = string(params, "value") ?? string(params, "text") else {
                return .err(code: "invalid_params", message: "Missing value", data: nil)
            }
            return shape(reading.resolveInteraction(.selectOption(params: params, value: value)))
        case "browser.scroll_into_view":
            return shape(reading.resolveInteraction(.scrollIntoView(params: params)))
        case "browser.highlight":
            return shape(reading.resolveInteraction(.highlight(params: params)))
        case "browser.press":
            guard let key = string(params, "key") else {
                return .err(code: "invalid_params", message: "Missing key", data: nil)
            }
            return shape(reading.resolveInteraction(.press(params: params, key: key)))
        case "browser.keydown":
            guard let key = string(params, "key") else {
                return .err(code: "invalid_params", message: "Missing key", data: nil)
            }
            return shape(reading.resolveInteraction(.keyDown(params: params, key: key)))
        case "browser.keyup":
            guard let key = string(params, "key") else {
                return .err(code: "invalid_params", message: "Missing key", data: nil)
            }
            return shape(reading.resolveInteraction(.keyUp(params: params, key: key)))
        case "browser.scroll":
            let dx = int(params, "dx") ?? 0
            let dy = int(params, "dy") ?? 0
            return shape(reading.resolveInteraction(.scroll(params: params, dx: dx, dy: dy)))
        default:
            return nil
        }
    }

    // MARK: - Payload shaping

    /// Shapes the wire result for one interaction resolution. The selector-action
    /// family (and the error branches that reuse shared app-side helpers) is
    /// carried pre-shaped; the `press`/`keydown`/`keyup`/`scroll` success is shaped
    /// here, byte-faithful to the legacy bodies (the workspace/surface identity
    /// plus the merged `--snapshot-after` walk).
    private func shape(_ resolution: ControlBrowserInteractionResolution) -> ControlCallResult {
        switch resolution {
        case .preShaped(let result):
            return result
        case .panelAction(let success):
            var payload: [String: JSONValue] = [
                "workspace_id": .string(success.workspaceID.uuidString),
                "workspace_ref": .string(success.workspaceRef),
                "surface_id": .string(success.surfaceID.uuidString),
                "surface_ref": .string(success.surfaceRef),
            ]
            for (key, value) in success.postSnapshot {
                payload[key] = value
            }
            return .ok(.object(payload))
        }
    }

    // MARK: - Param parsing (byte-faithful twins of v2String / v2RawString / v2Int)

    /// `v2String`: a trimmed, non-empty JSON string, or `nil` (whitespace-only is
    /// treated as absent; a non-string value never matches).
    private func string(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let raw)? = params[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `v2RawString`: the JSON string verbatim (empty allowed), or `nil` when the
    /// value is absent or not a JSON string.
    private func rawString(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let raw)? = params[key] else { return nil }
        return raw
    }

    /// `v2Int`: a JSON int, a number (via `NSNumber.intValue` to clamp/truncate
    /// like the legacy `as? NSNumber` path rather than trap), or a parsable string.
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
}
