import CmuxNextDesign
import Testing
@testable import CmuxNextSettingsWindow

/// A space row keeps every icon kind (R94): an emoji was drawn as an SF Symbol name (nothing
/// showed). The React page draws the rows from these values (host lists).
struct SettingsIconRowsTests {
    @Test func aSpaceRowKeepsItsEmoji() {
        #expect(SettingsListRow.space(id: "a", title: "Work", icon: "🚀").icon == .emoji("🚀"))
        #expect(SettingsListRow.space(id: "a", title: "Work", icon: "briefcase").icon == .symbol("briefcase"))
        #expect(SettingsListRow.space(id: "a", title: "Work", icon: nil).icon == .symbol("square.stack"))
        #expect(SettingsListRow(id: "m", title: "Mac", symbol: "server.rack").icon == .symbol("server.rack"))
    }
}
