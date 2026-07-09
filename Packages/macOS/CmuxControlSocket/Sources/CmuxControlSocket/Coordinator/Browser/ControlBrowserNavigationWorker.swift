internal import Foundation

/// The worker-lane RPC handler for the v2 `browser.*` navigation commands
/// (`browser.navigate` / `browser.back` / `browser.forward` / `browser.reload`),
/// lifted byte-faithfully from the former `TerminalController.v2BrowserNavigate`
/// / `v2BrowserNavSimple` bodies and their `v2BrowserJSCommandOnSocketWorker`
/// dispatch.
///
/// Owns the command dispatch, the `url` param parse (the byte-faithful twin of
/// `v2String`), and the reply payload shaping (the typed ``JSONValue`` twin of
/// the legacy `[String: Any]` dictionaries; the resulting Foundation object, and
/// therefore the encoded wire bytes, is identical). The app-coupled work
/// (`TabManager` / `surface_id` / workspace / browser-panel resolution, the
/// navigation calls, the ref computation, and the post-action snapshot) is
/// reached strictly through the ``ControlBrowserNavigationReading`` seam. It does
/// no socket I/O and never imports the app target.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: these commands run on the nonisolated
/// socket-worker lane (PR 5778 moved the JS-evaluating `browser.*` methods
/// there, which the `@MainActor` ``ControlCommandCoordinator`` cannot host).
/// ``handle(_:)`` and the seam's ``ControlBrowserNavigationReading/resolveNavigation(_:)``
/// are synchronous and run on the calling worker thread, exactly as the legacy
/// `nonisolated` bodies did; the seam's main-actor hops stay inside the
/// conformer.
public struct ControlBrowserNavigationWorker: Sendable {
    /// The live navigation seam. Injected at construction.
    private let reading: any ControlBrowserNavigationReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The navigation seam to read/drive.
    public init(reading: any ControlBrowserNavigationReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is a `browser.*` navigation worker-lane
    /// command, returning the typed result; returns `nil` for any other method so
    /// the caller can fall through (the remaining JS-evaluating `browser.*`
    /// methods are still served by the legacy app-side dispatcher).
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned method.
    public func handle(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "browser.navigate":
            return navigate(request.params)
        case "browser.back":
            return shape(reading.resolveNavigation(.back(params: request.params)))
        case "browser.forward":
            return shape(reading.resolveNavigation(.forward(params: request.params)))
        case "browser.reload":
            return shape(reading.resolveNavigation(.reload(params: request.params)))
        default:
            return nil
        }
    }

    // MARK: - navigate

    /// `browser.navigate` — `v2BrowserNavigate`. The `url` leaf is parsed here so
    /// the seam can enforce the legacy order (the `url` check ran after
    /// `TabManager` and `surface_id` resolution); the missing-url error is shaped
    /// by ``shape(_:)`` from ``ControlBrowserNavigationResolution/missingURL``.
    private func navigate(_ params: [String: JSONValue]) -> ControlCallResult {
        shape(reading.resolveNavigation(.navigate(params: params, url: string(params, "url"))))
    }

    // MARK: - Payload shaping

    /// Shapes the success/error payload for a navigation resolution, byte-faithful
    /// to the legacy `v2BrowserNavigate` / `v2BrowserNavSimple` bodies.
    private func shape(_ resolution: ControlBrowserNavigationResolution) -> ControlCallResult {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .invalidSurfaceID:
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        case .missingURL:
            return .err(code: "invalid_params", message: "Missing url", data: nil)
        case .surfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: "Surface not found or not a browser",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .navigated(let navigated):
            var payload: [String: JSONValue] = [
                "workspace_id": .string(navigated.workspaceID.uuidString),
                "workspace_ref": .string(navigated.workspaceRef),
                "surface_id": .string(navigated.surfaceID.uuidString),
                "surface_ref": .string(navigated.surfaceRef),
                "window_id": navigated.windowID.map { JSONValue.string($0.uuidString) } ?? .null,
                "window_ref": navigated.windowRef.map { JSONValue.string($0) } ?? .null,
            ]
            for (key, value) in navigated.postSnapshot {
                payload[key] = value
            }
            return .ok(.object(payload))
        }
    }

    // MARK: - Param parsing (byte-faithful twin of v2String)

    /// `v2String`: a trimmed, non-empty JSON string, or `nil` (whitespace-only is
    /// treated as absent).
    private func string(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let raw)? = params[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
