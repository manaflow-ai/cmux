import CmuxNextChiefPetWiring
import CmuxNextSidebar
import Foundation
import ImageIO

/// The sidebar's Chief item picture: the chosen pet character (`home.chiefPetMascot`) as its
/// avatar (the whole character on a transparent square), drawn untinted as the item's glyph in
/// every look, as the Home header wears it. One image per character, so the same pick compares
/// equal and an unrelated sidebar change does not redraw the item.
@MainActor
enum ChiefSidebarPicture {
    private static var loaded: [URL: SidebarFavicon] = [:]

    /// The picture of the character `mascot` names (an unknown or nil id: orb); nil when the
    /// bundled file cannot be read, and the item keeps its plain glyph.
    static func favicon(mascot: String?) -> SidebarFavicon? {
        guard let url = ChiefPetSettingsRows.avatarURL(of: mascot) else { return nil }
        if let known = loaded[url] { return known }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let favicon = SidebarFavicon(image)
        loaded[url] = favicon
        return favicon
    }
}
