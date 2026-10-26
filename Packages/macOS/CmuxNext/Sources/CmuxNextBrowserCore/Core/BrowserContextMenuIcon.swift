package import Foundation

/// The image before a page menu row's title, as Chrome draws it: an
/// extension's own icon on the row that holds its items, or a Chrome
/// vector icon (Translate, Cast). ``BrowserContextMenuBuilder`` draws it at
/// 16 pt, the size of Chrome's menu icons (`gfx::kFaviconSize`).
public nonisolated enum BrowserContextMenuIcon: Hashable, Sendable {
    /// An extension's manifest icon files: `oneX` for 1x screens (the
    /// smallest icon of at least 16 px), `twoX` for Retina (at least 32 px).
    /// Either may be nil; a missing file falls back to the other one.
    case image(oneX: String?, twoX: String?)
    /// An SF Symbol standing in for one of Chrome's vector icons; the menu
    /// tints it like its text.
    case symbol(String)
    /// Chrome's default extension icon (the puzzle piece), for an extension
    /// row whose extension the host could not tell or that has no icon.
    case defaultExtension

    /// The SF Symbol for ``defaultExtension``.
    public static let defaultExtensionSymbol = "browser.toolbar.extensions"
}
