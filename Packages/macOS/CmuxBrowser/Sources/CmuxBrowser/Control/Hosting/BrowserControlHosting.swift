public import Foundation
public import WebKit
public import CmuxControlSocket

/// The seam the app target's browser-control owner (`TerminalController`)
/// conforms to so package-side `browser.*` command logic can drive the parts of
/// the flow that must stay app-side: WebKit JavaScript evaluation against a live
/// `WKWebView` (whose main-actor hop threads the app's socket-command
/// focus-policy stack, which no package can reach) and the v2 protocol's stable
/// handle-ref minting.
///
/// The package returns `Sendable` values and ids through this seam; the live
/// `WKWebView` / tab / panel state stays owned by the host. This foundation
/// declares the witness signatures the host already satisfies; command bodies
/// are rerouted through the seam in later sub-slices.
///
/// ## Isolation
///
/// The eval and ref-read witnesses are `nonisolated`: they run on the socket
/// worker lane and hop to the main actor internally (the host's `v2MainSync`).
/// The ref-minting and ref-refresh witnesses are `@MainActor`: they mutate the
/// host's main-actor handle registry directly.
public protocol BrowserControlHosting: AnyObject {
    /// Evaluates `script` against `webView` on the worker lane (kicking a blank
    /// document first when the surface has never committed a navigation),
    /// returning the raw JS value or a failure message.
    nonisolated func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval,
        useEval: Bool,
        onIsolatedWorldFallback: (() -> Void)?
    ) -> BrowserJavaScriptResult

    /// Evaluates `script` against `webView` in the chosen JavaScript `world`,
    /// resolving the concrete `WKContentWorld` on the main actor.
    nonisolated func v2RunJavaScript(
        _ webView: WKWebView,
        script: String,
        timeout: TimeInterval,
        preferAsync: Bool,
        world: BrowserJSContentWorld
    ) -> BrowserJavaScriptResult

    /// The stable handle ref (e.g. `surface:3`) for `uuid` of the given `kind`,
    /// or `NSNull()` when `uuid` is `nil`.
    nonisolated func v2Ref(kind: ControlHandleKind, uuid: UUID?) -> Any

    /// Mints (or returns the existing) stable handle ref for `uuid` of the given
    /// `kind`.
    @MainActor func v2EnsureHandleRef(kind: ControlHandleKind, uuid: UUID) -> String

    /// Pre-mints handle refs for every currently known app object so callers can
    /// reference them by ref immediately after restore.
    @MainActor func v2RefreshKnownRefs()
}
