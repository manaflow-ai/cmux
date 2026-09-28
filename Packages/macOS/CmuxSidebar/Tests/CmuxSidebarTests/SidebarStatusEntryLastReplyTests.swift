import Foundation
import Testing

@testable import CmuxSidebar

@Suite struct SidebarStatusEntryLastReplyTests {
    @Test func lastReplyOnlyMovesForwardOrClears() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        #expect(SidebarStatusEntry.shouldReplaceLastReply(nil, with: earlier))
        #expect(SidebarStatusEntry.shouldReplaceLastReply(earlier, with: later))
        #expect(!SidebarStatusEntry.shouldReplaceLastReply(later, with: earlier))
        #expect(!SidebarStatusEntry.shouldReplaceLastReply(later, with: later))
        #expect(SidebarStatusEntry.shouldReplaceLastReply(later, with: nil))
        #expect(!SidebarStatusEntry.shouldReplaceLastReply(nil, with: nil))
    }

    @Test func withLastReplyAtKeepsEveryOtherField() {
        let entry = SidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            priority: 3,
            format: .markdown,
            timestamp: Date(timeIntervalSince1970: 500)
        )
        let reply = Date(timeIntervalSince1970: 900)
        let updated = entry.withLastReplyAt(reply)
        #expect(updated.lastReplyAt == reply)
        #expect(updated.withLastReplyAt(nil) == entry)
    }
}
