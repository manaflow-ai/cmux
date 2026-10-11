import AppKit

// cmux: MessagesLab ced183d Host.swift's context-menu glyphs and item icons (not vendored), for
// the pane's menu (PaneMenu.swift, PaneInteractions.swift). Differences are marked `cmux:`.

/// A palette cell's image: AppKit scales palette images to fit a 20 pt box (probe on
/// macOS 27: 16 and 20 pt images draw at 20 pt, 24 pt at 20/24, 34 pt at 20/34), and
/// Messages' glyphs are 20 pt, so the image is the glyph alone.
/// The context menu's palette glyphs as bitmaps (1x and 2x), drawn once and kept: a drawing-handler
/// image is drawn again by each new palette cell at each open (12 per open, about 3 ms of main-thread
/// work; menu bench profile). The glyphs do not depend on the appearance (fixed colours).
enum MenuGlyphs {
    private static var cache: [Reaction.Kind: NSImage] = [:]
    static func image(_ kind: Reaction.Kind) -> NSImage {
        if let i = cache[kind] { return i }
        let side = TapbackPickerView.glyphSize
        let img = NSImage(size: NSSize(width: side, height: side))
        for scale in [2, 1] {
            let px = CrashGuard.int(side, in: 1...256) * scale // cmux: no trap
            guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: DisplayScale.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { continue }
            // Flipped, as the drawing handler was (flipped: true).
            ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let box = CGRect(x: 0, y: 0, width: side, height: side)
            if let art = messagesArt(kind) {
                art.draw(in: scaled(box, Self.artScale), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if case let .emoji(e) = kind {
                PartRenderer.drawEmoji(e, in: box, ctx: ctx, scale: Self.emojiScale)
            } else { TapbackPickerView.drawGlyph(kind, in: box, ctx: ctx) }
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = img.size
            img.addRepresentation(rep)
        }
        cache[kind] = img
        return img
    }
    /// Messages' own tapback art (macOS 27: Messages.app's asset catalog has the six 3D tapback
    /// images, 44 pt, that its context menu draws in the palette row). macOS 26 has none of them:
    /// the drawn glyphs stay there. Read from the system bundle at run time, never copied.
    private static let messagesAssets = ["love": "heart_108", "like": "thumbsup_073", "dislike": "thumbsdown_069",
                                         "laugh": "haha-ENG_114", "emphasize": "exclamation_103", "question": "question_080"]
    private static let messagesBundle = Bundle(path: "/System/Applications/Messages.app")
    static func messagesArt(_ kind: Reaction.Kind) -> NSImage? {
        guard case let .tapback(t) = kind, let name = messagesAssets[t] else { return nil }
        // HA HA is the English art; another language keeps the drawn glyph.
        if t == "laugh", Locale.preferredLanguages.first.map({ !$0.hasPrefix("en") }) ?? false { return nil }
        return messagesBundle?.image(forResource: name)
    }
    /// The palette's last cell (Messages, macOS 27): the filled grinning face of the compose
    /// bar's emoji button (private `emoji.face.grinning`), white; else the public symbol.
    static func emojiPickerGlyph() -> NSImage {
        guard let g = FieldChrome.emojiGlyph(tinted: true)
            ?? NSImage(systemSymbolName: "face.smiling.inverse", accessibilityDescription: nil) else { return NSImage() }
        let side = TapbackPickerView.glyphSize, k = Self.faceSide / max(1, max(g.size.width, g.size.height)) // cmux: no 0 divide
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            let w = g.size.width * k, h = g.size.height * k
            g.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
            return true
        }
    }
    /// Palette ink against Messages (right-click-incoming-take1, 2x px, menu open): tapback art x1.40,
    /// recent emoji x0.89 (the emoji's font size), the grinning face 17 pt.
    static let artScale: CGFloat = 1.40, emojiScale: CGFloat = 0.89, faceSide: CGFloat = 17
    private static func scaled(_ r: CGRect, _ k: CGFloat) -> CGRect {
        let w = r.width * k, h = r.height * k
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
    /// Another display colour space: drawn again on next use.
    static func removeAll() { cache.removeAll() }
}

/// An NSMenuItem with a closure.
final class MenuAction: NSMenuItem {
    private let run: () -> Void
    /// cmux: the words alone (`title` also holds the icon's attachment character when an icon leads).
    let label: String
    init(title: String, symbol: String? = nil, _ run: @escaping () -> Void) {
        self.run = run
        label = title
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        // A private symbol (Messages' Attach Sticker icon `sticker.badge.plus`) comes from
        // CoreGlyphsPrivate, as the compose bar's `emoji.face.grinning`.
        guard let symbol, let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")?.image(forResource: symbol) else { return }
        // AppKit on macOS 27 does not draw NSMenuItem images in this menu; Messages (Catalyst)
        // shows them. The icon is drawn at the start of the title instead. VoiceOver reads the words only.
        let font = NSFont.menuFont(ofSize: 0)
        let cfg = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .medium)
        let sym = glyph.withSymbolConfiguration(cfg) ?? glyph
        let box = NSSize(width: Self.iconAdvance, height: ceil(font.ascender - font.descender))
        let icon = NSImage(size: box, flipped: false) { r in
            let s = sym.size
            let y = (r.height - s.height) / 2
            // A wide icon (sticker.badge.plus) starts at the title start, as in Messages, not left of it.
            sym.draw(in: CGRect(x: max(0, Self.iconCenterX - s.width / 2), y: y, width: s.width, height: s.height))
            NSColor.labelColor.set()
            CGRect(x: 0, y: 0, width: r.width, height: r.height).fill(using: .sourceAtop)
            return true
        }
        let att = NSTextAttachment()
        att.image = icon
        att.bounds = CGRect(x: 0, y: font.descender, width: box.width, height: box.height)
        let t = NSMutableAttributedString(attachment: att)
        t.append(NSAttributedString(string: title, attributes: [.font: font]))
        attributedTitle = t
        setAccessibilityTitle(title)
        setAccessibilityLabel(title)
    }
    /// Title start to the words when an icon leads, the icon's ink center from the title start,
    /// and its symbol size (Messages, right-click references; 11.7 pt from right-click-incoming-take1).
    static let iconAdvance: CGFloat = 20.5, iconCenterX: CGFloat = 5, iconPointSize: CGFloat = 11.7
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Attach Sticker's icon: Messages' private `sticker.badge.plus` when the system has it.
enum MenuSymbols {
    static let attachSticker: String = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")?
        .image(forResource: "sticker.badge.plus") != nil ? "sticker.badge.plus" : "face.smiling"
}
