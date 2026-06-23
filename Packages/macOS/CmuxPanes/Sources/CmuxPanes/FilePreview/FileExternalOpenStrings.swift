import Foundation

/// Localized, app-resolved strings for the external-open menus and controls.
///
/// `String(localized:)` must resolve against the app bundle's catalog, not this
/// package's bundle (which lacks the keys and would silently drop non-English
/// translations). So the package never localizes: it owns the strings as a
/// `Sendable` value seam, and the app resolves them (see `FileExternalOpenStrings.live`
/// in the app target) and passes this value in. This folds the former
/// `FileExternalOpenText` caseless namespace-enum onto a real value type.
public struct FileExternalOpenStrings: Sendable {
    /// Title for the "Open With" menu and submenu.
    public let openWithMenu: String
    /// Title for the generic "Open Externally" action (no resolved app).
    public let openExternally: String
    /// Title for "Reveal in Finder".
    public let revealInFinder: String
    /// Builds the "Open in <app>" title for a named application.
    public var openInApplication: @Sendable (_ applicationName: String) -> String

    /// Creates the strings seam from its resolved values and the per-app title
    /// builder.
    public init(
        openWithMenu: String,
        openExternally: String,
        revealInFinder: String,
        openInApplication: @escaping @Sendable (_ applicationName: String) -> String
    ) {
        self.openWithMenu = openWithMenu
        self.openExternally = openExternally
        self.revealInFinder = revealInFinder
        self.openInApplication = openInApplication
    }
}
