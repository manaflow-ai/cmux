import CmuxNextChiefPetWiring
import CmuxNextFloating
import CmuxNextSidebar
import Foundation
import ImageIO

/// The sidebar's Chief item picture: the default Chief's own upload's first frame, else the chosen
/// pet character (`home.chiefPetMascot`) as its avatar (the whole character on a transparent square), drawn untinted as the item's glyph in
/// every look, as the Home header wears it. One image per character, so the same pick compares
/// equal and an unrelated sidebar change does not redraw the item.
@MainActor
enum ChiefSidebarPicture {
    private static var loaded: [URL: SidebarFavicon] = [:]

    /// `picture` (`AppServices.characterPicture(of:)`): a worn upload comes with its first frame
    /// `image`, decoded off the main actor by ``ChiefAvatarUploads``; else the picture of the
    /// character `mascot` names (an unknown or nil id: orb), a small file in the app read once. Nil
    /// when that cannot be read, and the item keeps its plain glyph. An upload's file name is new per
    /// upload, so a new one is never the cached old one.
    static func favicon(mascot: String?, picture: URL? = nil, image: CGImage? = nil) -> SidebarFavicon? {
        guard let url = picture ?? ChiefPetSettingsRows.avatarURL(of: mascot) else { return nil }
        if let known = loaded[url] { return known }
        if let image {
            let favicon = SidebarFavicon(image)
            loaded[url] = favicon
            return favicon
        }
        // Only a character's own small picture in the app is read here; an upload comes decoded or not at all.
        guard ChiefPetMascot.allCases.contains(where: { $0.avatarURL == url }), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let favicon = SidebarFavicon(image)
        loaded[url] = favicon
        return favicon
    }
}
