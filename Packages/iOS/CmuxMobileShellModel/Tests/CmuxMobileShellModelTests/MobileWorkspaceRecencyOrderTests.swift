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

    @Test func thousandWorkspaceGroupedProjectionStaysWithinInteractionBudget() {
        let groupCount = 200
        let membersPerGroup = 4
        var workspaces: [MobileWorkspacePreview] = []
        var groups: [MobileWorkspaceGroupPreview] = []
        workspaces.reserveCapacity(groupCount * (membersPerGroup + 1))
        groups.reserveCapacity(groupCount)

        for groupIndex in 0..<groupCount {
            let groupID = MobileWorkspaceGroupPreview.ID(rawValue: "group-\(groupIndex)")
            let anchorID = MobileWorkspacePreview.ID(rawValue: "group-\(groupIndex)-member-0")
            groups.append(MobileWorkspaceGroupPreview(
                id: groupID,
                name: "Group \(groupIndex)",
                anchorWorkspaceID: anchorID
            ))
            for memberIndex in 0..<membersPerGroup {
                var workspace = ws(
                    "group-\(groupIndex)-member-\(memberIndex)",
                    activityAt: at(Double(groupIndex * membersPerGroup + memberIndex))
                )
                workspace.groupID = groupID
                workspaces.append(workspace)
            }
            workspaces.append(ws(
                "root-\(groupIndex)",
                activityAt: at(Double(groupIndex))
            ))
        }

        var items: [MobileWorkspaceListItem] = []
        let duration = ContinuousClock().measure {
            items = MobileWorkspaceRecencyOrder().groupedDisplayItems(
                workspaces,
                groups: groups
            )
        }

        #expect(workspaces.count == 1_000)
        #expect(items.count == 1_200)
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(
            duration < .milliseconds(100),
            "A 1,000-workspace projection took \(duration)."
        )
    }
}
