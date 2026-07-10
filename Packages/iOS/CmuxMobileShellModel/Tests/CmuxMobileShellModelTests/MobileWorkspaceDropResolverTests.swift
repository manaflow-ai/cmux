import CoreGraphics
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceDropResolverTests {
    private func workspace(
        _ id: String,
        group: String? = nil,
        pinned: Bool = false
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            isPinned: pinned,
            groupID: group.map { .init(rawValue: $0) },
            terminals: []
        )
    }

    private func group(
        _ id: String,
        anchor: String,
        collapsed: Bool = false,
        pinned: Bool = false
    ) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: id,
            isCollapsed: collapsed,
            isPinned: pinned,
            anchorWorkspaceID: .init(rawValue: anchor)
        )
    }

    private var workspaces: [MobileWorkspacePreview] {
        [
            workspace("anchor", group: "g"),
            workspace("member-1", group: "g"),
            workspace("member-2", group: "g"),
            workspace("root"),
            workspace("empty-anchor", group: "empty"),
            workspace("tail"),
        ]
    }

    private var groups: [MobileWorkspaceGroupPreview] {
        [group("g", anchor: "anchor"), group("empty", anchor: "empty-anchor")]
    }

    private var rows: [MobileWorkspaceDropRowFrame] {
        [
            row(.groupHeader("g"), y: 0),
            row(.workspace("member-1"), y: 40),
            row(.workspace("member-2"), y: 80),
            row(.workspace("root"), y: 120),
            row(.groupHeader("empty"), y: 160),
            row(.workspace("tail"), y: 200),
        ]
    }

    private func row(_ kind: MobileWorkspaceDropRowKind, y: CGFloat) -> MobileWorkspaceDropRowFrame {
        MobileWorkspaceDropRowFrame(kind: kind, frame: CGRect(x: 0, y: y, width: 240, height: 40))
    }

    private func resolve(
        _ workspaceID: String,
        groupDrag: Bool = false,
        x: CGFloat = 180,
        y: CGFloat,
        workspaces: [MobileWorkspacePreview]? = nil,
        groups: [MobileWorkspaceGroupPreview]? = nil,
        rows: [MobileWorkspaceDropRowFrame]? = nil
    ) -> MobileWorkspaceDropTarget? {
        MobileWorkspaceDropResolver().resolve(MobileWorkspaceDropRequest(
            payload: MobileWorkspaceDropPayload(workspaceID: .init(rawValue: workspaceID), isGroupDrag: groupDrag),
            rows: rows ?? self.rows,
            workspaces: workspaces ?? self.workspaces,
            groups: groups ?? self.groups,
            point: CGPoint(x: x, y: y),
            listMidlineX: 120
        ))
    }

    @Test func headerTopIsRootAndHeaderBottomEntersAtFirstMember() throws {
        let top = try #require(resolve("tail", y: 5))
        #expect(top.intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "anchor"))
        #expect(top.indicator.y == 0)
        #expect(!top.indicator.indented)

        let bottom = try #require(resolve("tail", y: 35))
        #expect(bottom.intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "member-1"))
        #expect(bottom.indicator.y == 40)
        #expect(bottom.indicator.indented)
    }

    @Test func headerMiddleAppendsAndHighlightsPopulatedGroup() throws {
        let target = try #require(resolve("root", y: 20))
        #expect(target.intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "empty-anchor"))
        #expect(target.indicator.kind == .highlightGroup("g"))
        #expect(target.indicator.y == 20)
    }

    @Test func headerMiddleMakesAnchorOnlyGroupDirectlyReachable() throws {
        let target = try #require(resolve("root", y: 180))
        #expect(target.intent == MobileWorkspaceMoveIntent(groupID: "empty", beforeWorkspaceID: "tail"))
        #expect(target.indicator.kind == .highlightGroup("empty"))
    }

    @Test func memberEdgesSelectSlotsInsideGroup() throws {
        let top = try #require(resolve("tail", y: 45))
        #expect(top.intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "member-1"))
        let bottom = try #require(resolve("tail", y: 75))
        #expect(bottom.intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "member-2"))
    }

    @Test func lastMemberBoundaryUsesHorizontalHierarchyLane() throws {
        let groupLane = try #require(resolve("tail", x: 180, y: 115))
        #expect(groupLane.intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "root"))
        #expect(groupLane.indicator.y == 120)
        #expect(groupLane.indicator.indented)

        let rootLane = try #require(resolve("tail", x: 40, y: 115))
        #expect(rootLane.intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root"))
        #expect(rootLane.indicator.y == 120)
        #expect(!rootLane.indicator.indented)
    }

    @Test func followingRootTopAlsoExposesBothBoundaryLanes() throws {
        #expect(try #require(resolve("tail", x: 180, y: 125)).intent
            == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "root"))
        #expect(try #require(resolve("tail", x: 40, y: 125)).intent
            == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root"))
    }

    @Test func groupDragOffersOnlyWholeGroupBoundaries() throws {
        let before = try #require(resolve("empty-anchor", groupDrag: true, y: 45))
        #expect(before.intent == MobileWorkspaceMoveIntent(
            groupID: nil,
            beforeWorkspaceID: "anchor",
            movesGroup: true
        ))
        let after = try #require(resolve("empty-anchor", groupDrag: true, y: 115))
        #expect(after.intent == MobileWorkspaceMoveIntent(
            groupID: nil,
            beforeWorkspaceID: "root",
            movesGroup: true
        ))
    }

    @Test func pinnedClampSnapsIndicatorToLegalTierBoundary() throws {
        let pinnedWorkspaces = [workspace("p1", pinned: true), workspace("p2", pinned: true), workspace("root")]
        let pinnedRows = [
            row(.workspace("p1"), y: 0),
            row(.workspace("p2"), y: 40),
            row(.workspace("root"), y: 80),
        ]
        let target = try #require(resolve(
            "p1",
            x: 40,
            y: 115,
            workspaces: pinnedWorkspaces,
            groups: [],
            rows: pinnedRows
        ))
        #expect(target.intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root"))
        #expect(target.indicator.y == 80)
    }

    @Test func identityLandingIsMarkedNoOp() throws {
        let target = try #require(resolve("root", x: 40, y: 125))
        #expect(target.intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root"))
        #expect(target.isNoOp)
    }

    @Test func unknownDragAndUnknownHoveredRowsAreRejected() {
        #expect(resolve("missing", y: 20) == nil)
        #expect(resolve("tail", y: 20, rows: [row(.workspace("missing"), y: 0)]) == nil)
        #expect(resolve("tail", y: 20, rows: [row(.groupHeader("missing"), y: 0)]) == nil)
    }

    @Test func emittedIntentsStayNormalizedAndMatchIndependentHostOrdering() {
        let payloads = [
            MobileWorkspaceDropPayload(workspaceID: "root", isGroupDrag: false),
            MobileWorkspaceDropPayload(workspaceID: "tail", isGroupDrag: false),
            MobileWorkspaceDropPayload(workspaceID: "empty-anchor", isGroupDrag: true),
        ]
        let points = rows.flatMap { row in
            [40.0, 180.0].flatMap { x in
                [row.frame.minY + 2, row.frame.midY, row.frame.maxY - 2].map { CGPoint(x: x, y: $0) }
            }
        }
        for payload in payloads {
            for point in points {
                let request = MobileWorkspaceDropRequest(
                    payload: payload,
                    rows: rows,
                    workspaces: workspaces,
                    groups: groups,
                    point: point,
                    listMidlineX: 120
                )
                guard let target = MobileWorkspaceDropResolver().resolve(request), !target.isNoOp else { continue }
                let intent = target.intent
                let renormalized = MobileWorkspaceMovePolicy(workspaces: workspaces, groups: groups)
                    .normalizedIntent(intent, movedWorkspaceID: payload.workspaceID)
                #expect(renormalized == intent)
                let optimistic = workspaces.applyingWorkspaceMoveIntent(
                    intent,
                    movedWorkspaceID: payload.workspaceID,
                    groups: groups
                )
                let host = MobileWorkspaceHostOrderSimulator(workspaces: workspaces, groups: groups)
                    .applying(intent, movedWorkspaceID: payload.workspaceID)
                #expect(optimistic.map(\.id) == host.map(\.id))
                #expect(optimistic.map(\.groupID) == host.map(\.groupID))
            }
        }
    }
}
