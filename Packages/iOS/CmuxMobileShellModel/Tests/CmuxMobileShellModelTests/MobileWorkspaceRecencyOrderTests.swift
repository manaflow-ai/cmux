import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for `.recentActivity` flat and grouped presentation order.
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

    @Test func thousandWorkspaceGroupedProjectionPreservesShapeOrderAndUniqueIDs() {
        let groupID = MobileWorkspaceGroupPreview.ID(rawValue: "large")
        let groupMemberCount = 999
        var workspaces: [MobileWorkspacePreview] = []
        workspaces.reserveCapacity(1_000)

        for memberIndex in 0..<groupMemberCount {
            var workspace = ws(
                "member-\(memberIndex)",
                activityAt: at(Double(memberIndex))
            )
            workspace.groupID = groupID
            workspaces.append(workspace)
        }
        workspaces.append(ws("root", activityAt: at(500)))
        let groups = [MobileWorkspaceGroupPreview(
            id: groupID,
            name: "Large Group",
            anchorWorkspaceID: .init(rawValue: "member-0")
        )]

        let items = MobileWorkspaceRecencyOrder().groupedDisplayItems(
            workspaces,
            groups: groups
        )

        #expect(workspaces.count == 1_000)
        #expect(items.count == 1_001)
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items.first?.id == "group.large")
        #expect(items.dropFirst().first?.id == "workspace.member-1")
        #expect(items[999].id == "groupFooter.large")
        #expect(items.last?.id == "workspace.root")
    }
}
