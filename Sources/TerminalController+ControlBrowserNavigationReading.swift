import CmuxControlSocket
import Foundation

/// App-side wiring for the worker-lane `browser.*` navigation control commands
/// (`browser.navigate` / `browser.back` / `browser.forward` / `browser.reload`).
///
/// The command bodies live in CmuxControlSocket's
/// ``ControlBrowserNavigationWorker``; this file supplies the live-state seam
/// (``ControlBrowserNavigationReading``) the worker reads through, plus the
/// synchronous worker-lane entry point that drives it.
///
/// ## Why the seam, not a direct call
///
/// `ControlBrowserNavigationWorker` is in a package that must not import `WebKit`
/// or the app target's per-surface browser state (the `BrowserPanel` navigation
/// API, the handle registry that mints `workspace_ref`/`surface_ref`/`window_ref`,
/// the post-action snapshot walk). ``ControlBrowserNavigationReading`` inverts
/// that: the package owns the protocol and the typed request/result values;
/// ``TerminalControllerBrowserNavigationReading`` conforms it over a `weak`
/// `TerminalController`, forwarding to the controller's single co-located
/// resolver (`controlResolveBrowserNavigation`). The resolver runs on the calling
/// socket-worker thread (the navigation and the post-snapshot accessibility walk
/// stay off the main actor exactly as the legacy `nonisolated` `v2BrowserNavigate`
/// / `v2BrowserNavSimple` bodies did), hopping to main only inside its
/// `v2MainSync` blocks.
extension TerminalController {
    /// Drives the package ``ControlBrowserNavigationWorker`` for one decoded
    /// `browser.*` navigation request from the synchronous socket-worker lane. The
    /// worker is synchronous (the navigation and the post-snapshot walk run on the
    /// worker thread, as the legacy bodies did), so no worker-thread→async bridge
    /// is needed. The worker only ever returns `nil` for non-navigation methods,
    /// which the dispatcher never routes here, so a `nil` result reports the same
    /// encode-failure response the legacy plumbing produced for an impossible
    /// payload.
    nonisolated func runBrowserNavigationWorker(_ request: ControlRequest) -> String {
        guard let worker = controlBrowserNavigationWorker,
              let result = worker.handle(request) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }
}

/// Conforms ``ControlBrowserNavigationReading`` over a `weak`
/// ``TerminalController``.
///
/// `@unchecked Sendable` (not `@MainActor`): ``resolveNavigation(_:)`` must run on
/// the socket-worker thread so the navigation and the post-action snapshot never
/// hold the main actor, matching the legacy `nonisolated` `v2BrowserNavigate` /
/// `v2BrowserNavSimple` bodies. The only stored member is a `weak` reference to
/// the app-lifetime `TerminalController` singleton; the controller's resolver is
/// `nonisolated` and performs its own `v2MainSync` hops internally, so no
/// isolation is required on the conformer. The `weak` reference is read on the
/// worker thread, which is safe for a singleton whose lifetime spans every
/// connection.
final class TerminalControllerBrowserNavigationReading: ControlBrowserNavigationReading, @unchecked Sendable {
    private weak var owner: TerminalController?

    /// Creates the conformer.
    /// - Parameter owner: The controller whose live browser state backs the seam.
    init(owner: TerminalController) {
        self.owner = owner
    }

    func resolveNavigation(_ request: ControlBrowserNavigationRequest) -> ControlBrowserNavigationResolution {
        guard let owner else {
            return .tabManagerUnavailable
        }
        return owner.controlResolveBrowserNavigation(request)
    }
}
