public import Foundation

/// The pre-parsed inputs for `browser.open_split`, mirroring the legacy
/// `v2BrowserOpenSplit` param reads.
public struct ControlBrowserOpenSplitInputs: Sendable, Equatable {
    /// The raw `url` param (trimmed, non-empty), if any. The app parses it.
    public let urlString: String?
    /// `respect_external_open_rules` (default `false`).
    public let respectExternalOpenRules: Bool
    /// The explicit `surface_id` source, if any.
    public let sourceSurfaceID: UUID?
    /// The requested `focus` (default `false`); the app applies its
    /// focus-allowance policy (`v2FocusAllowed`).
    public let focusRequested: Bool
    /// `show_omnibar` (default `true`).
    public let showOmnibar: Bool
    /// `transparent_background` (default `false`).
    public let transparentBackground: Bool
    /// The explicit `bypass_remote_proxy` param, or `nil` to let the app
    /// default it to the diff-viewer-URL check (legacy behavior).
    public let bypassRemoteProxy: Bool?

    /// Creates open-split inputs.
    ///
    /// - Parameters:
    ///   - urlString: The raw `url` param, if any.
    ///   - respectExternalOpenRules: `respect_external_open_rules`.
    ///   - sourceSurfaceID: The explicit `surface_id` source, if any.
    ///   - focusRequested: The requested `focus`.
    ///   - showOmnibar: `show_omnibar`.
    ///   - transparentBackground: `transparent_background`.
    ///   - bypassRemoteProxy: The explicit `bypass_remote_proxy`, if present.
    public init(
        urlString: String?,
        respectExternalOpenRules: Bool,
        sourceSurfaceID: UUID?,
        focusRequested: Bool,
        showOmnibar: Bool,
        transparentBackground: Bool,
        bypassRemoteProxy: Bool?
    ) {
        self.urlString = urlString
        self.respectExternalOpenRules = respectExternalOpenRules
        self.sourceSurfaceID = sourceSurfaceID
        self.focusRequested = focusRequested
        self.showOmnibar = showOmnibar
        self.transparentBackground = transparentBackground
        self.bypassRemoteProxy = bypassRemoteProxy
    }
}
