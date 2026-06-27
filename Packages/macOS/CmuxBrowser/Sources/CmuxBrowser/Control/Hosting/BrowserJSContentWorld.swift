/// A `Sendable` stand-in for `WKContentWorld` so nonisolated callers can pick a
/// JavaScript world without touching the main-actor-isolated
/// `WKContentWorld.page` / `.defaultClient` statics. The concrete world is
/// resolved on the main actor inside the host's `v2RunJavaScript`.
///
/// The package-side spelling of the app target's former nested
/// `TerminalController.V2JSContentWorld`; the app's
/// `typealias V2JSContentWorld = BrowserJSContentWorld` keeps every existing
/// `.page` / `.isolated` reference resolving unchanged.
public enum BrowserJSContentWorld: Sendable {
    /// The page's main JavaScript world.
    case page
    /// An isolated JavaScript world, used as the CSP-eval-block fallback.
    case isolated
}
