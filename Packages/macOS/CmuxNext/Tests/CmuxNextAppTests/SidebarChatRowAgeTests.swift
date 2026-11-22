@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A chat workspace's row age (`SidebarWorkspace.chatActivity`, acpmux `lane.since`): with
/// `sidebar.showTimestamps` on, a chat row draws its age at the right end of its title line, as a
/// terminal agent's row already did (Codex's thread list: the title on the left, the age on the right).
/// Off, the default, a row draws no age, as before.
@MainActor struct SidebarChatRowAgeTests {
    private static let today = Calendar.current.startOfDay(for: Date())
    private static let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: today)!

    private static func chat(_ activity: Date?) -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("chat"), title: "Change background color", kind: .harness)
        ws.chatActivity = activity
        return ws
    }

    private static func options(timestamps: Bool, expanded: Bool = false) -> SidebarLayoutOptions {
        var options = SidebarLayoutOptions()
        options.showsTimestamps = timestamps
        options.expanded = expanded
        options.now = today
        return options
    }

    @Test func aChatRowDrawsItsAgeOnTheTitleLineWithTimestampsOn() {
        let content = Self.options(timestamps: true).rowContent(Self.chat(Self.threeDaysAgo), machine: nil)
        #expect(content.badgeTime == "3d", "the chat row's age: \(content.badgeTime ?? "none")")
        #expect(content.detail == nil, "the age moved to a second line: \(content.detail ?? "")")
    }

    @Test func noAgeWithTimestampsOffTheDefault() {
        let content = Self.options(timestamps: false).rowContent(Self.chat(Self.threeDaysAgo), machine: nil)
        #expect(content.badgeTime == nil && content.time == nil)
    }

    @Test func anExpandedChatRowDrawsItsAgeOnTheTitleLine() {
        let content = Self.options(timestamps: true, expanded: true).rowContent(Self.chat(Self.threeDaysAgo), machine: nil)
        #expect(content.time == "3d" && content.trailingText == "3d")
    }

    @Test func theNewerOfTheTwoTimesReads() {
        var ws = Self.chat(Self.threeDaysAgo)
        ws.lastActivity = Calendar.current.date(byAdding: .day, value: -1, to: Self.today)
        #expect(ws.rowAge == ws.lastActivity)
        ws.lastActivity = Calendar.current.date(byAdding: .day, value: -9, to: Self.today)
        #expect(ws.rowAge == Self.threeDaysAgo)
        #expect(Self.chat(nil).rowAge == nil)
    }

    @Test func theChatTimeSurvivesTheRelaunchSnapshot() {
        let row = SidebarWorkspaceSnapshot(row: Self.chat(Self.threeDaysAgo)).restoredRow
        #expect(row.chatActivity == Self.threeDaysAgo)
    }
}
