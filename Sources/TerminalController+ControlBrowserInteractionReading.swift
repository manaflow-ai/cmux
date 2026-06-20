import CmuxControlSocket
import Foundation

/// App-side wiring for the worker-lane `browser.*` interaction control commands
/// (`browser.click` / `dblclick` / `hover` / `focus` / `type` / `fill` / `press` /
/// `keydown` / `keyup` / `check` / `uncheck` / `select` / `scroll` /
/// `scroll_into_view` / `highlight`).
///
/// The command bodies live in CmuxControlSocket's
/// ``ControlBrowserInteractionWorker``; this file supplies the live-state seam
/// (``ControlBrowserInteractionReading``) the worker reads through, plus the
/// synchronous worker-lane entry point that drives it.
///
/// ## Why the seam, not a direct call
///
/// `ControlBrowserInteractionWorker` is in a package that must not import `WebKit`
/// or the app target's per-surface browser state (`v2BrowserControl`'s per-action
/// script builders, the shared `v2BrowserSelectorAction` retry loop, the
/// element-ref table, the WebKit evaluation seam, the handle registry that mints
/// `workspace_ref`/`surface_ref`, the post-action snapshot walk).
/// ``ControlBrowserInteractionReading`` inverts that: the package owns the protocol
/// and the typed request/result values;
/// ``TerminalControllerBrowserInteractionReading`` conforms it over a `weak`
/// `TerminalController`, forwarding to the controller's single co-located resolver
/// (`controlResolveBrowserInteraction`). The resolver runs on the calling
/// socket-worker thread (the blocking JavaScript evaluation and the post-snapshot
/// walk stay off the main actor exactly as the legacy `nonisolated` interaction
/// bodies did), hopping to main only inside its existing helpers.
extension TerminalController {
    /// Drives the package ``ControlBrowserInteractionWorker`` for one decoded
    /// `browser.*` interaction request from the synchronous socket-worker lane. The
    /// worker is synchronous (the JS evaluation and the post-snapshot walk run on
    /// the worker thread, as the legacy bodies did), so no worker-thread→async
    /// bridge is needed. The worker only ever returns `nil` for non-interaction
    /// methods, which the dispatcher never routes here, so a `nil` result reports
    /// the same encode-failure response the legacy plumbing produced for an
    /// impossible payload.
    nonisolated func runBrowserInteractionWorker(_ request: ControlRequest) -> String {
        guard let worker = controlBrowserInteractionWorker,
              let result = worker.handle(request) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }
}

/// Conforms ``ControlBrowserInteractionReading`` over a `weak`
/// ``TerminalController``.
///
/// `@unchecked Sendable` (not `@MainActor`): ``resolveInteraction(_:)`` must run on
/// the socket-worker thread so the blocking JavaScript evaluation never holds the
/// main actor, matching the legacy `nonisolated` interaction bodies. The only
/// stored member is a `weak` reference to the app-lifetime `TerminalController`
/// singleton; the controller's resolver is `nonisolated` and performs its own
/// `v2MainSync` hops internally, so no isolation is required on the conformer. The
/// `weak` reference is read on the worker thread, which is safe for a singleton
/// whose lifetime spans every connection.
final class TerminalControllerBrowserInteractionReading: ControlBrowserInteractionReading, @unchecked Sendable {
    private weak var owner: TerminalController?

    /// Creates the conformer.
    /// - Parameter owner: The controller whose live browser state backs the seam.
    init(owner: TerminalController) {
        self.owner = owner
    }

    func resolveInteraction(_ request: ControlBrowserInteractionRequest) -> ControlBrowserInteractionResolution {
        guard let owner else {
            // Mirrors the panel-resolution head when no TabManager is reachable;
            // the legacy `v2BrowserWithPanelContext` returned this exact error.
            return .preShaped(.err(code: "unavailable", message: "TabManager not available", data: nil))
        }
        return owner.controlResolveBrowserInteraction(request)
    }
}
