public import Foundation

/// The per-panel React Grab actions the app target drives against a browser
/// panel during a toggle.
///
/// The concrete browser panel lives in the app target (it owns the WebKit
/// `WKWebView` and the round-trip pasteback state), so a lower package cannot
/// import it. The panel conforms to this protocol and ``ReactGrabController``
/// forwards each step through it. The method bodies are byte-faithful lifts of
/// the former `TabManager.performReactGrabToggle(in:browserPanelId:returnTerminalPanelId:)`.
///
/// `@MainActor` because every action mutates WebKit/AppKit state on the main
/// thread; the protocol exists where its callers live.
@MainActor
public protocol ReactGrabBrowserActing: AnyObject {
    /// The browser panel's identity (its panel id).
    var id: UUID { get }

    /// Arms a pasteback round-trip so a successful copy returns to `panelId`.
    func armReactGrabRoundTrip(returnTo panelId: UUID)

    /// Clears any armed pasteback round-trip.
    /// - Parameter reason: a short diagnostic tag describing the trigger.
    func clearReactGrabRoundTrip(reason: String)

    /// Requests explicit first-responder focus into the web view.
    /// - Returns: whether focus was moved synchronously.
    @discardableResult
    func requestExplicitWebViewFocus() -> Bool

    /// Ensures React Grab is active, re-using the existing bridge session when
    /// possible. Used when a pasteback round-trip is armed.
    func ensureReactGrabActive() async

    /// Toggles React Grab, injecting the script when it is not yet active.
    /// Used when no pasteback round-trip is armed.
    func toggleOrInjectReactGrab() async
}
