public import Foundation

/// The action a file-external-open menu item performs when chosen.
///
/// Carried inside a ``FileExternalOpenMenuActionPayload`` on each menu item's
/// `representedObject` and read back by ``FileExternalOpenMenuActionTarget``.
public enum FileExternalOpenMenuPayloadAction: Sendable {
    /// Open the file. A `nil` application URL means "let the system pick the
    /// default handler"; otherwise open in the application at that URL.
    case open(applicationURL: URL?)
    /// Reveal the file in Finder.
    case revealInFinder
}
