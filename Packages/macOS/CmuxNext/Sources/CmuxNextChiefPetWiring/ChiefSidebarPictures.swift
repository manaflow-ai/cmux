public import CmuxNextSidebar
public import CoreGraphics
public import Foundation

/// The sidebar's Chief item picture: the default Chief's own upload's first frame, drawn untinted as
/// the item's glyph in every look. With no upload it keeps its plain glyph (no pet picture, Lawrence
/// 2026-10-31). One image per upload, so the same upload compares equal and an unrelated sidebar
/// change does not redraw the item. AppServices owns the one instance.
@MainActor
public final class ChiefSidebarPictures {
    private var loaded: [URL: SidebarFavicon] = [:]

    public init() {}

    /// The worn upload's still `still` (`AppServices.wornUpload(of:)`), with its first frame `image`
    /// decoded off the main actor by ``ChiefAvatarUploads`` (nil until it is). An upload's file name is
    /// new per upload, so a new one is never the cached old one.
    public func favicon(still: URL?, image: CGImage?) -> SidebarFavicon? {
        guard let still else { return nil }
        if let known = loaded[still] { return known }
        guard let image else { return nil }
        let favicon = SidebarFavicon(image)
        loaded[still] = favicon
        return favicon
    }
}
