internal import Foundation

/// Localized titles for the file-external-open menu.
///
/// Resolved app-side (where `String(localized:)` binds to the app bundle, which
/// owns the catalog keys) and injected into ``FileExternalOpenMenuBuilder``.
/// Kept as a value type rather than a static-string namespace so this package
/// never resolves localization against its own (key-less) bundle.
public struct FileExternalOpenMenuStrings: Sendable {
    /// Title of the "Open With" menu and submenu.
    public let openWithMenu: String
    /// Title used when no specific handler application is known ("Open Externally").
    public let openExternally: String
    /// Title of the "Reveal in Finder" item.
    public let revealInFinder: String
    /// `printf`-style format with a single `%@` for the application name, e.g. `"Open in %@"`.
    public let openInApplicationFormat: String

    /// Creates the menu titles.
    public init(
        openWithMenu: String,
        openExternally: String,
        revealInFinder: String,
        openInApplicationFormat: String
    ) {
        self.openWithMenu = openWithMenu
        self.openExternally = openExternally
        self.revealInFinder = revealInFinder
        self.openInApplicationFormat = openInApplicationFormat
    }

    /// Title for "open in a named application", substituting `applicationName`
    /// into ``openInApplicationFormat``.
    public func openInApplication(_ applicationName: String) -> String {
        String(format: openInApplicationFormat, applicationName)
    }
}
