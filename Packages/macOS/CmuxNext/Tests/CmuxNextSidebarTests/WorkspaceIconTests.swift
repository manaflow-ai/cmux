import AppKit
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
}
