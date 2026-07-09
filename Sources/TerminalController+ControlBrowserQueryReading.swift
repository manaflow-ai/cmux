import CmuxControlSocket
import Foundation

/// App-side wiring for the worker-lane `browser.find.*` control commands.
///
/// The command bodies live in CmuxControlSocket's ``ControlBrowserQueryWorker``;
/// this file supplies the live-state seam (``ControlBrowserQueryReading``) the
/// worker reads through, plus the synchronous worker-lane entry point that drives
/// it.
///
/// ## Why the seam, not a direct call
///
/// `ControlBrowserQueryWorker` is in a package that must not import `WebKit` or
/// the app target's per-surface browser state (`v2BrowserControl`'s finder-script
/// builders, the element-ref table, the WebKit evaluation seam).
/// ``ControlBrowserQueryReading`` inverts that: the package owns the protocol and
/// the typed request/result values; ``TerminalControllerBrowserQueryReading``
/// conforms it over a `weak` `TerminalController`, forwarding to the controller's
/// single co-located resolver (`controlResolveBrowserFind`). The resolver runs on
/// the calling socket-worker thread (the blocking JavaScript evaluation stays
/// off the main actor exactly as the legacy `nonisolated` `v2BrowserFind*` bodies
/// did), hopping to main only inside its existing helpers.
extension TerminalController {
    /// Drives the package ``ControlBrowserQueryWorker`` for one decoded
    /// `browser.find.*` request from the synchronous socket-worker lane. The
    /// worker is synchronous (the JS evaluation blocks the worker thread, as the
    /// legacy bodies did), so no worker-thread→async bridge is needed. The worker
    /// only ever returns `nil` for non-`browser.find.*` methods, which the
    /// dispatcher never routes here, so a `nil` result reports the same
    /// encode-failure response the legacy plumbing produced for an impossible
    /// payload.
    nonisolated func runBrowserQueryWorker(_ request: ControlRequest) -> String {
        guard let worker = controlBrowserQueryWorker,
              let result = worker.handle(request) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }
}

/// Conforms ``ControlBrowserQueryReading`` over a `weak` ``TerminalController``.
///
/// `@unchecked Sendable` (not `@MainActor`): ``resolveFind(_:)`` must run on the
/// socket-worker thread so the blocking JavaScript evaluation never holds the
/// main actor, matching the legacy `nonisolated` `v2BrowserFind*` bodies. The
/// only stored member is a `weak` reference to the app-lifetime
/// `TerminalController` singleton; the controller's resolver is `nonisolated` and
/// performs its own `v2MainSync` hops internally, so no isolation is required on
/// the conformer. The `weak` reference is read on the worker thread, which is
/// safe for a singleton whose lifetime spans every connection.
final class TerminalControllerBrowserQueryReading: ControlBrowserQueryReading, @unchecked Sendable {
    private weak var owner: TerminalController?

    /// Creates the conformer.
    /// - Parameter owner: The controller whose live browser state backs the seam.
    init(owner: TerminalController) {
        self.owner = owner
    }

    func resolveFind(_ request: ControlBrowserFindRequest) -> ControlBrowserFindResolution {
        guard let owner else {
            return .panelUnavailable(.err(code: "unavailable", message: "TabManager not available", data: nil))
        }
        return owner.controlResolveBrowserFind(request)
    }

    func resolveQuery(_ request: ControlBrowserQueryActionRequest) -> ControlCallResult {
        guard let owner else {
            // Mirrors the panel-resolution head when no TabManager is reachable;
            // the legacy `v2BrowserWithPanel`/`v2BrowserWithPanelContext` head
            // returned this exact error.
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return owner.controlResolveBrowserQuery(request)
    }
}
