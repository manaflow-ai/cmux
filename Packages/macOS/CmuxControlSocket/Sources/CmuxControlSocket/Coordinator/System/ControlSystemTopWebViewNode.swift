public import Foundation

/// One webview row of a `system.top` / `system.memory` browser surface (the
/// legacy per-`webviews` dictionary of `v2TopWorkspaceNode`, minus the
/// coordinator-minted refs).
///
/// The app target builds exactly one of these per browser surface, mirroring
/// the legacy single-element `webviews` array; non-browser surfaces carry an
/// empty webview list.
public struct ControlSystemTopWebViewNode: Sendable, Equatable {
    /// The owning surface's panel identifier (the webview id/ref are derived
    /// from it by the coordinator: `"<surfaceID>:webview"`).
    public let surfaceID: UUID
    /// The webview's index within its surface (always `0`, matching the legacy
    /// single-webview emission).
    public let index: Int
    /// The browser panel's display title.
    public let title: String
    /// The current URL string (empty when the browser has no URL, matching the
    /// legacy `?? ""`).
    public let url: String
    /// The web-content process identifier, if WebKit reported one.
    public let pid: Int?
    /// The opaque per-webview lifecycle payload (the legacy
    /// `BrowserPanel.webViewLifecycleTopPayload()` dictionary, bridged to a JSON
    /// value app-side because its shape is frozen app-resident copy).
    public let lifecycle: JSONValue

    /// Creates a webview node.
    ///
    /// - Parameters:
    ///   - surfaceID: The owning surface's panel identifier.
    ///   - index: The webview index within its surface.
    ///   - title: The browser panel's display title.
    ///   - url: The current URL string (empty when absent).
    ///   - pid: The web-content process identifier, if any.
    ///   - lifecycle: The bridged lifecycle payload.
    public init(
        surfaceID: UUID,
        index: Int,
        title: String,
        url: String,
        pid: Int?,
        lifecycle: JSONValue
    ) {
        self.surfaceID = surfaceID
        self.index = index
        self.title = title
        self.url = url
        self.pid = pid
        self.lifecycle = lifecycle
    }
}
