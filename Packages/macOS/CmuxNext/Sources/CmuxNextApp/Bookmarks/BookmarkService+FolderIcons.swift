import AppKit
import CmuxNextBookmarks
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextTabs

/// Bookmark folder icons (`bookmark-icon-v1`, cx-qno.11.3): a folder's own
/// icon, the shared icon string (an emoji, an SF Symbol name, or a stored image
/// or SVG asset), drawn in place of the folder symbol on the bookmarks bar, its
/// folder menus and the manager page. Bookmarks live in the home daemon, which
/// also stores their image and SVG icons. A stored icon draws the folder symbol
/// until it is read; the bar that drew it then redraws (no polling).
extension BookmarkService {
    /// The machine that keeps bookmarks and their stored icons.
    var iconOwner: DaemonService { services.machines.local }

    /// Folder icons can be set and removed: the home daemon serves `bookmark-icon-v1`.
    var supportsFolderIcons: Bool { iconOwner.supports(DaemonCapability.bookmarkIcon.rawValue) }

    /// Folder `node`'s own icon at `side` points for the bar and its menus: a
    /// symbol as a template image the bar tints, an emoji or a stored asset in
    /// its own colors. Nil without one, for a symbol this Mac cannot draw, and
    /// while a stored asset loads: the caller draws the folder symbol.
    func folderIconImage(of node: BookmarkNode, side: CGFloat) -> NSImage? {
        guard node.isFolder, let icon = node.icon else { return nil }
        if case .symbol(let name)? = IconValue(wire: icon) {
            guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
            return NSImage.icon(symbol: name, size: side)
        }
        return folderIconCGImage(of: node).map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }
    }

    /// Folder `node`'s emoji or stored asset icon as an image drawn in its own
    /// colors (the manager page's rows draw a symbol themselves). Reads the
    /// asset store, so a view drawn from it redraws when the asset lands.
    func folderIconCGImage(of node: BookmarkNode) -> CGImage? {
        guard node.isFolder, let icon = node.icon else { return nil }
        switch IconValue(wire: icon) {
        case .emoji?:
            guard case .image(let image)? = TabUserIcon.shared.icon(icon) else { return nil }
            return image.cgImage
        case .image?, .svg?:
            return IconAssetImages.shared.image(icon, owner: iconOwner)?.image
        case .symbol?, nil:
            return nil
        }
    }

    /// True when folder `node` names a stored asset not read yet; the bar
    /// that drew the folder symbol for it redraws when it lands.
    func awaitFolderIcon(of node: BookmarkNode) -> Bool {
        guard node.isFolder, let icon = node.icon else { return false }
        switch IconValue(wire: icon) {
        case .image?, .svg?: break
        case .emoji?, .symbol?, nil: return false
        }
        guard IconAssetImages.shared.image(icon, owner: iconOwner) == nil else { return false }
        if !awaitedFolderIcons.contains(icon) { awaitedFolderIcons.insert(icon) }
        return true
    }

    /// Redraws the bars that drew the folder symbol for a stored icon when it lands.
    func followFolderIcons() {
        // task-owner: lives as long as the service; event-driven (Observation)
        folderIconObservation = Task { [weak self] in
            for await landed in ObservationStream({ [weak self] in self?.landedAwaitedFolderIcons() ?? [] }) {
                guard let self else { return }
                guard !landed.isEmpty else { continue }
                awaitedFolderIcons.subtract(landed)
                guard showsBar else { continue }
                for chrome in chromes.values where chrome.entry != nil && chrome.source.awaitsFavicons { chrome.bar.reload() }
            }
        }
    }

    /// Reads the awaited icons and each one's image, so the stream above runs
    /// again when one is added or lands.
    private func landedAwaitedFolderIcons() -> Set<String> {
        awaitedFolderIcons.filter { IconAssetImages.shared.image($0, owner: iconOwner) != nil }
    }
}
