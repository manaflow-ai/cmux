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
