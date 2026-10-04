import CmuxNextDesign
import Testing
@testable import CmuxNextSettingsWindow

/// Settings draws every icon kind (R94): a space's emoji was drawn as an SF
/// Symbol name (nothing showed), and a browser profile's symbol name was
/// drawn as text (its name showed).
struct SettingsIconRowsTests {
    @Test func aSpaceRowKeepsItsEmoji() {
        #expect(SettingsListRow.space(id: "a", title: "Work", icon: "🚀").icon == .emoji("🚀"))
        #expect(SettingsListRow.space(id: "a", title: "Work", icon: "briefcase").icon == .symbol("briefcase"))
        #expect(SettingsListRow.space(id: "a", title: "Work", icon: nil).icon == .symbol("square.stack"))
        #expect(SettingsListRow(id: "m", title: "Mac", symbol: "server.rack").icon == .symbol("server.rack"))
    }

    @Test func aBrowserProfileAvatarDrawsSymbolsAsImages() {
        #expect(BrowserProfileAvatar.content(SettingsBrowserProfileRow(id: "w", name: "Work", icon: "briefcase.fill")) == .symbol("briefcase.fill"))
        #expect(BrowserProfileAvatar.content(SettingsBrowserProfileRow(id: "w", name: "Work", icon: "💼")) == .text("💼"))
        #expect(BrowserProfileAvatar.content(SettingsBrowserProfileRow(id: "w", name: "work")) == .text("W"))
        #expect(BrowserProfileAvatar.content(SettingsBrowserProfileRow(id: "w", name: "")) == .text("?"))
    }
}
