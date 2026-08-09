import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for the `.recentActivity` flat presentation order.
@Suite struct MobileWorkspaceRecencyOrderTests {
    private func ws(
        _ id: String,
        activityAt: Date? = nil,
        pinned: Bool = false
    ) -> MobileWorkspacePreview {
        var preview = MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            terminals: []
        )
        preview.lastActivityAt = activityAt
        preview.isPinned = pinned
        return preview
    }

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    @Test func mostRecentActivityComesFirstAcrossComputers() {
        let ordered = MobileWorkspaceRecencyOrder().displayOrder([
            ws("old", activityAt: at(100)),
            ws("newest", activityAt: at(300)),
            ws("middle", activityAt: at(200)),
        ])
        #expect(ordered.map(\.id.rawValue) == ["newest", "middle", "old"])
    }

    @Test func pinnedRowsStayFirstLikeTheFlatList() {
        let ordered = MobileWorkspaceRecencyOrder().displayOrder([
            ws("newest", activityAt: at(300)),
            ws("pinned-old", activityAt: at(100), pinned: true),
        ])
        #expect(ordered.map(\.id.rawValue) == ["pinned-old", "newest"])
    }

    @Test func rowsWithoutTimestampsSortLastKeepingIncomingOrder() {
        let ordered = MobileWorkspaceRecencyOrder().displayOrder([
            ws("no-time-1"),
            ws("recent", activityAt: at(300)),
            ws("no-time-2"),
        ])
        #expect(ordered.map(\.id.rawValue) == ["recent", "no-time-1", "no-time-2"])
    }

    @Test func equalTimestampsKeepIncomingOrder() {
        let ordered = MobileWorkspaceRecencyOrder().displayOrder([
            ws("first", activityAt: at(200)),
            ws("second", activityAt: at(200)),
            ws("third", activityAt: at(200)),
        ])
        #expect(ordered.map(\.id.rawValue) == ["first", "second", "third"])
    }

    @Test func pinnedTiesBreakByRecency() {
        let ordered = MobileWorkspaceRecencyOrder().displayOrder([
            ws("pinned-old", activityAt: at(100), pinned: true),
            ws("pinned-new", activityAt: at(300), pinned: true),
        ])
        #expect(ordered.map(\.id.rawValue) == ["pinned-new", "pinned-old"])
    }
}
