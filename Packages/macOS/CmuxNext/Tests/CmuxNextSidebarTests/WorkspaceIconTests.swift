import AppKit
import CmuxAgentBrands
import CmuxNextIcons
import Testing
@testable import CmuxNextSidebar

/// Workspace icons from the record's `icon` string remain custom emoji or SF
/// Symbols. Rows without a custom icon use the built-in type glyph pack.
@MainActor @Suite struct WorkspaceIconTests {
    @Test func parseTellsEmojiFromSymbols() {
        #expect(WorkspaceIcon.parse("🚀") == .emoji("🚀"))
        #expect(WorkspaceIcon.parse("🇯🇵") == .emoji("🇯🇵"))
        #expect(WorkspaceIcon.parse("👩‍💻") == .emoji("👩‍💻"))
        #expect(WorkspaceIcon.parse("house") == .symbol("house"))
        // Not one emoji and not a symbol name: no icon (one rule, IconValue).
        #expect(WorkspaceIcon.parse("🚀🚀") == nil)
        #expect(WorkspaceIcon.parse("a b") == nil)
    }

    @Test func anEmojiIconDrawsAsText() {
        let view = SidebarIconView()
        view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        view.configure(icon: .emoji("🚀"))
        view.layoutSubtreeIfNeeded()
        #expect(view.emojiText == "🚀")
        view.configure(icon: .symbol("house"))
        #expect(view.emojiText == nil)
    }

    @Test func aBuiltInTypeIconDrawsWhenTheWorkspaceHasNoCustomIcon() throws {
        let view = SidebarIconView()
        view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        view.configure(icon: nil, fallback: .terminal)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(!view.isHidden)
        #expect(!image.isHidden)
        #expect(image.image != nil)
        #expect(view.emojiText == nil)
    }

    @Test func anEmojiWithAColorDrawsOnAChip() {
        let view = SidebarIconView()
        view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        view.configure(icon: .emoji("🚀", chip: .green))
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        #expect(view.emojiText == "🚀")
        #expect(view.showsChip)
        view.configure(icon: .emoji("🚀"))
        view.updateLayer()
        #expect(!view.showsChip)
    }

    /// The type glyph draws at row size (the size an icon takes beside the
    /// row's title), not a secondary glyph's size.
    @Test func aTypeGlyphDrawsAtRowSize() throws {
        let view = SidebarIconView()
        view.configure(icon: nil, fallback: .terminal)
        let image = try #require(view.subviews.compactMap { $0 as? NSImageView }.first?.image)
        let side = CGFloat.iconRowSize(forLabelPointSize: SidebarStyle.titleFont.pointSize)
        #expect(image.size == NSSize(width: side, height: side))
    }

    /// A row showing an agent wears that agent's mark instead of the generic glyph.
    @Test func anAgentRowDrawsItsHarnessMark() throws {
        let view = SidebarIconView()
        view.configure(icon: nil, fallback: .agentChat, brand: "claude")
        let image = try #require(view.subviews.compactMap { $0 as? NSImageView }.first?.image)
        let mark = try #require(AgentBrandCatalog.templateImage(brand: "claude", size: 16))
        #expect(mark.accessibilityDescription != nil)
        #expect(image.accessibilityDescription == mark.accessibilityDescription)
        // A user's icon still wins over the mark.
        view.configure(icon: .emoji("🚀"), fallback: .agentChat, brand: "claude")
        #expect(view.emojiText == "🚀")
    }
}

/// Lawrence (nxdog70): a smiling-face workspace icon was cut at its top and left edge next to
/// the name. The whole glyph draws inside the icon box at every row icon size: its ink keeps
/// the shape it has when drawn unclipped, and it stays inside the box.
@MainActor @Suite struct WorkspaceIconClipTests {
    /// The ink bounding box (pixels, top-left origin) of a bitmap, or nil when empty.
    static func inkBox(_ rep: NSBitmapImageRep) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The emoji's own ink aspect, drawn large on an open canvas.
    static func referenceAspect(_ text: String) throws -> CGFloat {
        let size = NSSize(width: 160, height: 160)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 160, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 80)]).draw(at: NSPoint(x: 30, y: 30))
        NSGraphicsContext.restoreGraphicsState()
        _ = size
        let box = try #require(inkBox(rep))
        return box.width / box.height
    }

    /// Renders `icon` in a box of `side` points, centered on a canvas three times as big.
    static func render(_ icon: WorkspaceIcon, side: CGFloat) throws -> (ink: CGRect, box: CGRect) {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: side * 3, height: side * 3))
        let view = SidebarIconView()
        view.frame = NSRect(x: side, y: side, width: side, height: side)
        canvas.addSubview(view)
        view.configure(icon: icon)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / canvas.bounds.width
        let ink = try #require(inkBox(rep), "the icon drew nothing at \(side) pt")
        return (CGRect(x: ink.minX / scale, y: ink.minY / scale, width: ink.width / scale, height: ink.height / scale),
                CGRect(x: side, y: side, width: side, height: side))
    }

    @Test(arguments: [12.0, 14.0, 16.0, 18.0, 20.0, 24.0, 28.0])
    func anEmojiIconDrawsWholeInsideItsBox(side: Double) throws {
        let reference = try Self.referenceAspect("😀")
        let (ink, box) = try Self.render(.emoji("😀"), side: side)
        #expect(abs(ink.width / ink.height - reference) < 0.12,
                "the emoji keeps its shape (not cut): ink \(ink) aspect \(ink.width / ink.height) vs \(reference)")
        #expect(box.insetBy(dx: -0.5, dy: -0.5).contains(ink), "the emoji stays in its box: ink \(ink) box \(box)")
        #expect(ink.height >= box.height * 0.6, "the emoji fills its box: ink \(ink) box \(box)")
    }

    @Test(arguments: [12.0, 16.0, 20.0, 28.0])
    func aSymbolIconDrawsInsideItsBox(side: Double) throws {
        let (ink, box) = try Self.render(.symbol("house"), side: side)
        #expect(box.insetBy(dx: -0.5, dy: -0.5).contains(ink), "the symbol stays in its box: ink \(ink) box \(box)")
    }
}
