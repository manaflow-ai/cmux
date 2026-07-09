public import Foundation
public import WebKit

/// A package-safe snapshot of the resolved context for a `browser.*` command:
/// the owning workspace id, the target surface id, and the live `WKWebView`
/// automation runs against.
///
/// The package-side replacement for the app target's former nested
/// `TerminalController.V2BrowserPanelContext`, dropping that struct's app-side
/// `BrowserPanel` field (which no package can name) and keeping only the
/// id pair plus the WebKit view the worker-lane JS-eval witnesses already accept.
/// The host resolves this on the main actor (where the live tab/panel state
/// lives) and hands it to package-side command logic.
///
/// Not `Sendable`: it holds a `WKWebView`, a main-actor-isolated reference type.
/// Consumers stay on the main actor when reading ``webView`` and hop to the
/// nonisolated eval lane only by passing the view into the host witnesses.
public struct BrowserPanelContextSnapshot {
    /// The id of the workspace owning the surface.
    public let workspaceID: UUID
    /// The id of the browser surface the command targets.
    public let surfaceID: UUID
    /// The live web view automation evaluates against.
    public let webView: WKWebView

    /// Creates a snapshot of a resolved browser-panel context.
    public init(workspaceID: UUID, surfaceID: UUID, webView: WKWebView) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.webView = webView
    }
}
