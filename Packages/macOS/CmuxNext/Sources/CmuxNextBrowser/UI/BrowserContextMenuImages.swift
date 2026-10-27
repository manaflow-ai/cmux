import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextIcons

// memory: fixed: one entry per menu icon: the SF Symbol names of the page menu (a fixed catalog;
// symbols are vector templates) and one per enabled extension with menu rows, whose 1x and 2x files
// are the manifest's smallest icons of at least 16 and 32 px (BrowserExtensionMenuSource), about
// 5 KB of pixels each; the builder that owns it is one per process.
/// The 16 pt images of page menu rows (``BrowserContextMenuIcon``), made
/// once per icon. Main thread, like the menus that show them.
final class BrowserContextMenuImages {
    /// Chrome's menu icon size (`gfx::kFaviconSize`).
    static let side: CGFloat = 16
    private var cache: [BrowserContextMenuIcon: NSImage] = [:]

    func image(for icon: BrowserContextMenuIcon) -> NSImage {
        if let image = cache[icon] { return image }
        let image = Self.make(icon)
        cache[icon] = image
        return image
    }

    /// An extension's files as one image with a 1x and a 2x representation, decoded to 16 and 32 px;
    /// Chrome's default extension icon when neither file loads, or a file is past the main thread's image
    /// gate (as Chrome's `ExtensionIconManager` shows the default icon until the extension's own is loaded,
    /// chrome/browser/extensions/extension_icon_manager.cc).
    static func make(_ icon: BrowserContextMenuIcon) -> NSImage {
        let size = NSSize(width: side, height: side)
        switch icon {
        case .image(let oneX, let twoX):
            // One decode per file, at the larger size it is used at.
            var files: [(path: String, pixels: Int)] = []
            for (path, scale) in [(oneX, 1), (twoX, 2)] {
                guard let path else { continue }
                let pixels = Int(side) * scale
                if let index = files.firstIndex(where: { $0.path == path }) {
                    files[index].pixels = max(files[index].pixels, pixels)
                } else {
                    files.append((path, pixels))
                }
            }
            // decode: in the menu's turn (it opens now and tracks the run loop), once per icon, only within
            // IconAssetDecode.mainThreadPixels (256 x 256 px); the files are the manifest's 16 and 32 px icons.
            let reps = files.compactMap { file -> NSImageRep? in
                guard let data = try? Data(blockingContentsOf: URL(fileURLWithPath: file.path)),
                      let bitmap = IconAssetDecode.thumbnail(data, types: IconAssetDecode.bitmapTypes, maxPixelSize: file.pixels,
                                                             pixelLimit: IconAssetDecode.mainThreadPixels) else { return nil }
                let rep = NSBitmapImageRep(cgImage: bitmap)
                rep.size = size
                return rep
            }
            guard !reps.isEmpty else { return make(.defaultExtension) }
            let image = NSImage(size: size)
            for rep in reps { image.addRepresentation(rep) }
            return image
        case .symbol(let name):
            return symbol(name) ?? symbol(BrowserContextMenuIcon.defaultExtensionSymbol) ?? NSImage(size: size)
        case .defaultExtension:
            return symbol(BrowserContextMenuIcon.defaultExtensionSymbol) ?? NSImage(size: size)
        }
    }

    /// `name` as a menu row's SF Symbol (`NSImage.menuSymbol`), a template the menu inks like
    /// its title: an SF Symbol name a page or extension gives, or a pack name (Chrome's
    /// `browser.menu.*` icons) as the SF Symbol the icon catalog pairs with it.
    private static func symbol(_ name: String) -> NSImage? {
        NSImage.menuSymbol(name)
    }
}
