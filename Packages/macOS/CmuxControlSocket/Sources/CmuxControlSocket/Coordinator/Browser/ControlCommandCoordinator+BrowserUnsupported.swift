internal import Foundation

/// The deliberately-unsupported, main-actor `browser.*` methods that report a
/// stable `not_supported` error on WKWebView (no CDP equivalent):
/// `browser.viewport.set` / `browser.geolocation.set` / `browser.offline.set` /
/// `browser.trace.start` / `browser.trace.stop` / `browser.screencast.start` /
/// `browser.screencast.stop` / `browser.input_mouse` / `browser.input_keyboard`
/// / `browser.input_touch`, plus the network-interception trio
/// `browser.network.route` / `browser.network.unroute` / `browser.network.requests`.
///
/// Lifted byte-faithfully from the former `TerminalController.v2Browser*`
/// bodies and their shared `v2BrowserNotSupported` head. The ten pure stubs
/// carry no app state and build the `not_supported` result directly. The three
/// network methods keep a per-surface ring log of attempted interceptions; that
/// log is mutable app-lifecycle state (cleared on surface teardown), so it stays
/// app-side behind the ``ControlBrowserContext`` seam and the coordinator only
/// records into it / reads it back.
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the unsupported/network
    /// browser methods this coordinator owns, returning the typed result;
    /// returns `nil` otherwise so the caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not owned here.
    func handleBrowserUnsupported(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "browser.viewport.set":
            return browserNotSupported(
                "browser.viewport.set",
                details: "WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP"
            )
        case "browser.geolocation.set":
            return browserNotSupported(
                "browser.geolocation.set",
                details: "WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP"
            )
        case "browser.offline.set":
            return browserNotSupported(
                "browser.offline.set",
                details: "WKWebView does not expose reliable per-tab offline emulation"
            )
        case "browser.trace.start":
            return browserNotSupported(
                "browser.trace.start",
                details: "Playwright trace artifacts are not available on WKWebView"
            )
        case "browser.trace.stop":
            return browserNotSupported(
                "browser.trace.stop",
                details: "Playwright trace artifacts are not available on WKWebView"
            )
        case "browser.network.route":
            return browserNetworkRoute(request.params, action: "route")
        case "browser.network.unroute":
            return browserNetworkRoute(request.params, action: "unroute")
        case "browser.network.requests":
            return browserNetworkRequests(request.params)
        case "browser.screencast.start":
            return browserNotSupported(
                "browser.screencast.start",
                details: "WKWebView does not expose CDP screencast streaming"
            )
        case "browser.screencast.stop":
            return browserNotSupported(
                "browser.screencast.stop",
                details: "WKWebView does not expose CDP screencast streaming"
            )
        case "browser.input_mouse":
            return browserNotSupported(
                "browser.input_mouse",
                details: "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll"
            )
        case "browser.input_keyboard":
            return browserNotSupported(
                "browser.input_keyboard",
                details: "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup"
            )
        case "browser.input_touch":
            return browserNotSupported(
                "browser.input_touch",
                details: "Raw CDP touch injection is unavailable on WKWebView"
            )
        default:
            return nil
        }
    }

    /// The standard not-supported error (the typed twin of
    /// `v2BrowserNotSupported`): `not_supported` with a `details` payload.
    private func browserNotSupported(_ method: String, details: String) -> ControlCallResult {
        .err(
            code: "not_supported",
            message: "\(method) is not supported on WKWebView",
            data: .object(["details": .string(details)])
        )
    }

    /// `browser.network.route` / `browser.network.unroute` — record the attempt
    /// (when a `surface_id` resolves) and report not-supported, byte-faithful to
    /// the legacy bodies.
    private func browserNetworkRoute(_ params: [String: JSONValue], action: String) -> ControlCallResult {
        if let surfaceID = uuid(params, "surface_id") {
            browserContextForUnsupported?.controlBrowserRecordUnsupportedNetworkRequest(
                surfaceID: surfaceID,
                action: action,
                params: params
            )
        }
        return browserNotSupported(
            "browser.network.\(action)",
            details: "WKWebView does not provide CDP-style request interception/mocking"
        )
    }

    /// `browser.network.requests` — return the recorded interception log for the
    /// resolved surface (inside the `not_supported` error data), byte-faithful to
    /// the legacy body.
    private func browserNetworkRequests(_ params: [String: JSONValue]) -> ControlCallResult {
        if let surfaceID = uuid(params, "surface_id") {
            let items = browserContextForUnsupported?.controlBrowserUnsupportedNetworkRequests(surfaceID: surfaceID) ?? []
            return .err(
                code: "not_supported",
                message: "browser.network.requests is not supported on WKWebView",
                data: .object([
                    "details": .string("Request interception logs are unavailable without CDP network hooks"),
                    "recorded_requests": .array(items),
                ])
            )
        }
        return browserNotSupported(
            "browser.network.requests",
            details: "Request interception logs are unavailable without CDP network hooks"
        )
    }

    /// The browser-domain view of the seam, mirroring `handleBrowser`'s private
    /// `browserContext`. (Named distinctly to avoid colliding with that
    /// file-private accessor in the same type.)
    private var browserContextForUnsupported: (any ControlBrowserContext)? {
        context
    }
}
