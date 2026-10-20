import AppKit

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

    /// An extension's files as one image with a 1x and a 2x representation;
    /// Chrome's default extension icon when neither file loads.
    static func make(_ icon: BrowserContextMenuIcon) -> NSImage {
        let size = NSSize(width: side, height: side)
        switch icon {
        case .image(let oneX, let twoX):
            let reps = [oneX, twoX].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .compactMap { NSImage(contentsOfFile: $0)?.representations.max { $0.pixelsWide < $1.pixelsWide } }
            guard !reps.isEmpty else { return make(.defaultExtension) }
            let image = NSImage(size: size)
            for rep in reps {
                guard let copy = rep.copy() as? NSImageRep else { continue }
                copy.size = size
                image.addRepresentation(copy)
            }
            return image
        case .symbol(let name):
            return symbol(name) ?? symbol(BrowserContextMenuIcon.defaultExtensionSymbol) ?? NSImage(size: size)
        case .defaultExtension:
            return symbol(BrowserContextMenuIcon.defaultExtensionSymbol) ?? NSImage(size: size)
        }
    }

    /// `name` drawn in a 16 pt square; a template, so the menu tints it.
    private static func symbol(_ name: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return nil }
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let fit = base.size
            let scale = min(rect.width / max(fit.width, 1), rect.height / max(fit.height, 1), 1)
            let drawn = NSSize(width: fit.width * scale, height: fit.height * scale)
            base.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2,
                                 width: drawn.width, height: drawn.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}
