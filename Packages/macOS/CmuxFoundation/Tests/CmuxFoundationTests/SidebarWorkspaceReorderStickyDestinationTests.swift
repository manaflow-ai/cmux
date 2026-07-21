import CoreGraphics
import Foundation
import Testing
@testable import CmuxFoundation

/// The group/root-ambiguous boundary (a group's last-member edge) resolves
/// toward where the drag already previews, so entering and leaving the last
/// slot of a group needs no pointer-lane precision.
@Suite struct SidebarWorkspaceReorderStickyDestinationTests {
    private let top = UUID()
    private let anchor = UUID()
    private let member = UUID()
    private let below = UUID()
    private let dragged = UUID()
    private let groupId = UUID()

    private var workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot] {
        [
            .init(id: top, isPinned: false, groupId: nil),
            .init(id: anchor, isPinned: false, groupId: groupId),
            .init(id: member, isPinned: false, groupId: groupId),
            .init(id: dragged, isPinned: false, groupId: nil),
            .init(id: below, isPinned: false, groupId: nil),
        ]
    }

    private var groups: [SidebarWorkspaceReorderGroupSnapshot] {
        [.init(id: groupId, anchorWorkspaceId: anchor, isPinned: false)]
    }

    /// Rows: top(0-30), header(30-60), member(60-90), dragged(90-120), below(120-150).
    private var targets: [SidebarWorkspaceReorderDropTarget] {
        [
            .init(workspaceId: top, groupId: nil, isGroupHeader: false, frame: CGRect(x: 0, y: 0, width: 200, height: 30)),
            .init(workspaceId: anchor, groupId: groupId, isGroupHeader: true, frame: CGRect(x: 0, y: 30, width: 200, height: 30)),
            .init(workspaceId: member, groupId: groupId, isGroupHeader: false, frame: CGRect(x: 0, y: 60, width: 200, height: 30)),
            .init(workspaceId: dragged, groupId: nil, isGroupHeader: false, frame: CGRect(x: 0, y: 90, width: 200, height: 30)),
            .init(workspaceId: below, groupId: nil, isGroupHeader: false, frame: CGRect(x: 0, y: 120, width: 200, height: 30)),
        ]
    }

    private func resolvePlan(
        pointY: CGFloat,
        pointX: CGFloat = 10,
        sticky: SidebarWorkspaceReorderStickyDestination,
        dragging: UUID? = nil
    ) -> SidebarWorkspaceReorderDropPlan? {
        SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: pointX, y: pointY),
                draggedWorkspaceId: dragging ?? dragged,
                workspaces: workspaces,
                groups: groups,
                targets: targets,
                stickyDestination: sticky
            )
        )
    }

    /// The last-member bottom edge (ambiguous) with a group-sticky drag
    /// stays a group commit, even at the far-left pointer lane.
    @Test func groupStickyKeepsTailSlotInGroup() throws {
        let plan = try #require(resolvePlan(pointY: 85, sticky: .group(groupId)))
        guard case .reorder(_, _, let explicitGroupId) = plan.action else {
            Issue.record("expected reorder action")
            return
        }
        #expect(explicitGroupId == groupId)
    }

    /// A top-level drag enters the group's last slot once the floating row's
    /// center crosses the last member's center.
    @Test func topLevelStickyEntersTailWhileCenterOverlapsLastMember() throws {
        let plan = try #require(resolvePlan(pointY: 85, sticky: .topLevel))
        guard case .reorder(_, _, let explicitGroupId) = plan.action else {
            Issue.record("expected reorder action")
            return
        }
        #expect(explicitGroupId == groupId)
    }

    /// Once the floating center reaches the next root row's top half, a
    /// top-level drag stays root instead of snapping into the preceding group.
    @Test func topLevelStickyKeepsNextRootRowAtRoot() throws {
        let plan = try #require(resolvePlan(pointY: 95, sticky: .topLevel, dragging: top))
        guard case .reorder(_, _, let explicitGroupId) = plan.action else {
            Issue.record("expected reorder action")
            return
        }
        #expect(explicitGroupId == nil)
    }

    /// A drag already previewing inside the group stays there through the
    /// next root row's top half, preventing boundary chatter.
    @Test func groupStickyHoldsThroughNextRootRowTopHalf() throws {
        let plan = try #require(resolvePlan(pointY: 95, sticky: .group(groupId), dragging: top))
        guard case .reorder(_, _, let explicitGroupId) = plan.action else {
            Issue.record("expected reorder action")
            return
        }
        #expect(explicitGroupId == groupId)
    }

    /// Crossing the next root row's midpoint exits the group on the same
    /// center-to-center threshold used for ordinary reordering.
    @Test func groupStickyReleasesAtNextRootRowMidpoint() throws {
        let plan = try #require(resolvePlan(pointY: 110, sticky: .group(groupId), dragging: top))
        guard case .reorder(_, _, let explicitGroupId) = plan.action else {
            Issue.record("expected reorder action")
            return
        }
        #expect(explicitGroupId == nil)
    }

    /// Stickiness releases a half row past the group's last visible row, so
    /// a group at the end of the list can still be exited downward.
    @Test func groupStickyReleasesFarBelowList() throws {
        // The group is the last thing in the list; the dragged row starts
        // at the top and hovers far below everything.
        let tailWorkspaces: [SidebarWorkspaceReorderWorkspaceSnapshot] = [
            .init(id: dragged, isPinned: false, groupId: nil),
            .init(id: anchor, isPinned: false, groupId: groupId),
            .init(id: member, isPinned: false, groupId: groupId),
        ]
        let tailTargets: [SidebarWorkspaceReorderDropTarget] = [
            .init(workspaceId: dragged, groupId: nil, isGroupHeader: false, frame: CGRect(x: 0, y: 0, width: 200, height: 30)),
            .init(workspaceId: anchor, groupId: groupId, isGroupHeader: true, frame: CGRect(x: 0, y: 30, width: 200, height: 30)),
            .init(workspaceId: member, groupId: groupId, isGroupHeader: false, frame: CGRect(x: 0, y: 60, width: 200, height: 30)),
        ]
        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 10, y: 106),
                draggedWorkspaceId: dragged,
                workspaces: tailWorkspaces,
                groups: groups,
                targets: tailTargets,
                stickyDestination: .group(groupId)
            )
        ))
        guard case .reorder(_, _, let explicitGroupId) = plan.action else {
            Issue.record("expected reorder action")
            return
        }
        #expect(explicitGroupId == nil)
    }
}
