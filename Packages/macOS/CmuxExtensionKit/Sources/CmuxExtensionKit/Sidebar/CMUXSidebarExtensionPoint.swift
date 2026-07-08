import Foundation

/// Public identifiers for the CMUX sidebar ExtensionKit surface.
@_spi(CmuxHostTransport)
public enum CmuxSidebarExtensionPoint {
    /// Base extension point identifier third-party sidebar extensions register against.
    ///
    /// Production builds use this value verbatim. Dev/dogfood builds may scope the point
    /// per build tag (e.g. `com.cmuxterm.app.debug.my-tag.cmux.sidebar`) so that concurrent debug
    /// builds and their bundled sample extensions don't share one extension point. The
    /// per-tag value is injected at build time (see ``identifierInfoPlistKey``) and never
    /// committed to source.
    public static let baseIdentifier = "com.cmuxterm.app.cmux.sidebar"

    /// Info.plist key a bundle may declare to override the extension point identifier.
    ///
    /// Populated at build time from the `CMUX_SIDEBAR_EXTENSION_POINT_ID` build setting
    /// (via Info.plist variable substitution), so the resolved id lives only in the built
    /// bundle, never in tracked source. Absent or empty means "use ``baseIdentifier``".
    public static let identifierInfoPlistKey = "CMUXSidebarExtensionPointIdentifier"

    /// Resolves the extension point identifier for a bundle.
    ///
    /// Reads ``identifierInfoPlistKey`` from `bundle`, falling back to ``baseIdentifier``
    /// when the bundle declares no override. The host passes its own bundle so the value
    /// matches whatever the build injected; tests can pass a fixture bundle.
    ///
    /// - Parameter bundle: Bundle to read the override from. Defaults to `.main`.
    /// - Returns: The effective extension point identifier.
    public static func identifier(in bundle: Bundle = .main) -> String {
        guard let override = bundle.object(forInfoDictionaryKey: identifierInfoPlistKey) as? String,
              !override.isEmpty else {
            return baseIdentifier
        }
        return override
    }

    /// Default ExtensionKit scene identifier hosted inside the cmux sidebar.
    public static let defaultSceneID = "sidebar"
}
