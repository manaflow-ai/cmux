import AppKit
import Testing
@testable import CmuxNextSidebar

/// Workspace icons from the record's `icon` string: one emoji (drawn as
/// text) or an SF Symbol name (Lawrence 2026-10-02: custom emoji and images
/// for workspaces and Home; images wait for a store blob op).
@MainActor @Suite struct WorkspaceIconTests {
    @Test func parseTellsEmojiFromSymbols() {
        #expect(WorkspaceIcon.parse("🚀") == .emoji("🚀"))
        #expect(WorkspaceIcon.parse("🇯🇵") == .emoji("🇯🇵"))
        #expect(WorkspaceIcon.parse("👩‍💻") == .emoji("👩‍💻"))
        #expect(WorkspaceIcon.parse("house") == .symbol("house"))
        #expect(WorkspaceIcon.parse("🚀🚀") == .symbol("🚀🚀"))
        #expect(!WorkspaceIcon.isEmoji("a") && !WorkspaceIcon.isEmoji("1"))
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
}
