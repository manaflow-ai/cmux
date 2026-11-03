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
    static func image(_ kind: Reaction.Kind) -> NSImage { image(kind, art: messagesArt) }
    /// cmux: `art` gives a kind's Messages art: read here on main by default; `warm()` passes the art it
    /// read off the main thread.
    private static func image(_ kind: Reaction.Kind, art artOf: (Reaction.Kind) -> NSImage?) -> NSImage {
        if let i = cache[kind] { return i }
        let messages = artOf(kind)  // cmux: once for both scales
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
            if let art = messages {
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
        messagesArtName(kind).flatMap { messagesBundle?.image(forResource: $0) }
    }
    /// cmux: the asset name of a kind's Messages art, or nil when it keeps the drawn glyph.
    private static func messagesArtName(_ kind: Reaction.Kind) -> String? {
        guard case let .tapback(t) = kind, let name = messagesAssets[t] else { return nil }
        // HA HA is the English art; another language keeps the drawn glyph.
        if t == "laugh", Locale.preferredLanguages.first.map({ !$0.hasPrefix("en") }) ?? false { return nil }
        return name
    }
    /// cmux: the six tapback images by asset name, read on a utility queue: not on the main thread (the first
    /// `image(forResource:)` opens Messages' asset catalog: file reads and a dispatch_sync onto CoreUI's serial
    /// `com.apple.CoreUI.UICatalog-cache` queue, 2.2 ms on the main thread at the first warm, blocking probe
    /// 2026-10-24) and not on the cooperative pool (file I/O). Utility: a prefetch nothing waits for.
    /// A GCD utility thread, not BackgroundWork: this shared package cannot reach CmuxNextWakeups (lead, 2026-10-25).
    private static func loadArt() async -> [String: NSImage] {
        let bundle = messagesBundle, names = Array(messagesAssets.values)
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                var read: [String: NSImage] = [:]
                for name in names { read[name] = bundle?.image(forResource: name) }
                done.resume(returning: read)
            }
        }
    }
    /// The palette's last cell (Messages, macOS 27): the filled grinning face of the compose
    /// bar's emoji button (private `emoji.face.grinning`), white; else the public symbol.
    /// MessagesLab 7518134: made once per appearance (it was made at every open, inside the menu's open on main).
    private static var pickerGlyphs: [String: NSImage] = [:]
    static func emojiPickerGlyph() -> NSImage {
        let key = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? ""
        if let i = pickerGlyphs[key] { return i }
        let i = makeEmojiPickerGlyph()
        pickerGlyphs[key] = i
        return i
    }
    private static func makeEmojiPickerGlyph() -> NSImage {
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
    static func removeAll() { cache.removeAll(); pickerGlyphs.removeAll() }
    /// MessagesLab 7518134 (ChatController.warmUp, and after a display move): the six tapbacks, the
    /// recent emoji and the picker glyph. Images only.
    static func warm() {
        RecentEmoji.list.prefix(5).forEach { _ = image(.emoji($0)) }
        _ = emojiPickerGlyph()
        // cmux: the tapbacks once their art is read off the main thread; a menu that opens first draws
        // its own. Drawn on main, in the display's colour space of that moment.
        let tapbacks = TapbackGlyph.all.map { Reaction.Kind.tapback($0) }.filter { cache[$0] == nil }
        guard !tapbacks.isEmpty else { return }
        Task { @MainActor in  // task-owner: a one-shot prefetch that ends on its own; nothing cancels it
            let tapbackArt: [String: NSImage] = await loadArt()
            tapbacks.forEach { _ = image($0) { kind in messagesArtName(kind).flatMap { tapbackArt[$0] } } }
        }
    }
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
        guard let symbol, let icon = Self.icon(symbol) else { return }
        // AppKit on macOS 27 does not draw NSMenuItem images in this menu; Messages (Catalyst)
        // shows them. The icon is drawn at the start of the title instead. VoiceOver reads the words only.
        let font = NSFont.menuFont(ofSize: 0)
        let box = icon.size
        let att = NSTextAttachment()
        att.image = icon
        att.bounds = CGRect(x: 0, y: font.descender, width: box.width, height: box.height)
        let t = NSMutableAttributedString(attachment: att)
        t.append(NSAttributedString(string: title, attributes: [.font: font]))
        attributedTitle = t
        setAccessibilityTitle(title)
        setAccessibilityLabel(title)
    }
    /// MessagesLab 7518134: the title icons, one per symbol and appearance for the app's life (made
    /// at every open before, inside the menu's open on main). Kept per appearance: labelColor.
    private static var icons: [String: NSImage] = [:]
    static func icon(_ symbol: String) -> NSImage? {
        let key = "\(symbol)|\(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "")"
        if let i = icons[key] { return i }
        // A private symbol (Messages' Attach Sticker icon `sticker.badge.plus`) comes from
        // CoreGlyphsPrivate, as the compose bar's `emoji.face.grinning`.
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")?.image(forResource: symbol) else { return nil }
        let font = NSFont.menuFont(ofSize: 0)
        let cfg = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .medium)
        let sym = glyph.withSymbolConfiguration(cfg) ?? glyph
        let box = NSSize(width: Self.iconAdvance, height: ceil(font.ascender - font.descender))
        // Still a drawing handler: AppKit draws it in the menu row's own appearance.
        let icon = NSImage(size: box, flipped: false) { r in
            let s = sym.size
            let y = (r.height - s.height) / 2
            // A wide icon (sticker.badge.plus) starts at the title start, as in Messages, not left of it.
            sym.draw(in: CGRect(x: max(0, Self.iconCenterX - s.width / 2), y: y, width: s.width, height: s.height))
            NSColor.labelColor.set()
            CGRect(x: 0, y: 0, width: r.width, height: r.height).fill(using: .sourceAtop)
            return true
        }
        icons[key] = icon
        return icon
    }
    /// The message menu's icons, made at the first idle (ChatController.warmUp).
    static func warm() {
        ["plus.magnifyingglass", "arrowshape.turn.up.left", MenuSymbols.attachSticker, "square.and.arrow.up"].forEach { _ = icon($0) }
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
