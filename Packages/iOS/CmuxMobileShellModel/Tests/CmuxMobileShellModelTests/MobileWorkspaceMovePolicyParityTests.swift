import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceMovePolicyParityTests {
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

    @Test func stackedAnchorOnlyGroupsRenderAsHeadersWithoutSyntheticRows() {
        let workspaces = [
            workspace("a", group: "a"),
            workspace("b", group: "b"),
            workspace("c", group: "c"),
        ]
        let groups = [
            group("a", anchor: "a"),
            group("b", anchor: "b"),
            group("c", anchor: "c"),
        ]
        #expect(MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups) == [
            .groupHeader(groups[0], hasUnread: false),
            .groupHeader(groups[1], hasUnread: false),
            .groupHeader(groups[2], hasUnread: false),
        ])
    }

    @Test func appliedIntentsMatchIndependentHostSimulatorAcrossFixtures() {
        let fixtures: [([MobileWorkspacePreview], [MobileWorkspaceGroupPreview])] = [
            (
                [
                    workspace("pa", group: "p"),
                    workspace("pm", group: "p"),
                    workspace("root-p", pinned: true),
                    workspace("root-p2", pinned: true),
                    workspace("ua", group: "u"),
                    workspace("up", group: "u", pinned: true),
                    workspace("um", group: "u"),
                    workspace("root"),
                ],
                [group("p", anchor: "pa", pinned: true), group("u", anchor: "ua")]
            ),
            (
                [
                    workspace("a", group: "g"),
                    workspace("b", group: "g", pinned: true),
                    workspace("root"),
                    workspace("c", group: "h"),
                    workspace("d", group: "h"),
                ],
                [group("g", anchor: "a"), group("h", anchor: "c", collapsed: true)]
            ),
            (
                [workspace("solo", group: "s"), workspace("pinned", pinned: true), workspace("root")],
                [group("s", anchor: "solo")]
            ),
            (
                [
                    workspace("a", group: "a"),
                    workspace("b", group: "b"),
                    workspace("c", group: "c"),
                    workspace("root"),
                ],
                [
                    group("a", anchor: "a"),
                    group("b", anchor: "b"),
                    group("c", anchor: "c"),
                ]
            ),
        ]
        for (workspaces, groups) in fixtures {
            let rendered = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
            for sourceIndex in rendered.indices {
                for destination in 0...rendered.count {
                    guard let move = rendered.moveIntent(
                        workspaces: workspaces,
                        groups: groups,
                        sourceOffsets: IndexSet(integer: sourceIndex),
                        destination: destination
                    ), let movedWorkspaceID = movedWorkspaceID(for: rendered[sourceIndex]) else {
                        continue
                    }
                    let optimistic = workspaces.applyingWorkspaceMoveIntent(
                        move,
                        movedWorkspaceID: movedWorkspaceID,
                        groups: groups
                    )
                    assertGroupBlocksAreContiguousAndAnchorFirst(optimistic, groups: groups)
                    assertPinnedTiersHold(optimistic, groups: groups)
                    let simulatedHost = MobileWorkspaceHostOrderSimulator(
                        workspaces: workspaces,
                        groups: groups
                    ).applying(move, movedWorkspaceID: movedWorkspaceID)
                    #expect(optimistic.map(\.id) == simulatedHost.map(\.id))
                    #expect(optimistic.map(\.groupID) == simulatedHost.map(\.groupID))
                }
            }
        }
    }

    private func movedWorkspaceID(
        for item: MobileWorkspaceListItem
    ) -> MobileWorkspacePreview.ID? {
        switch item {
        case .workspace(let workspace, _):
            workspace.id
        case .groupHeader(let group, _):
            group.anchorWorkspaceID
        case .groupFooter:
            nil
        }
    }

    private func assertGroupBlocksAreContiguousAndAnchorFirst(
        _ workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for group in groups {
            let indices = workspaces.indices.filter { workspaces[$0].groupID == group.id }
            guard !indices.isEmpty else { continue }
            #expect(indices == Array(indices.first!...indices.last!), sourceLocation: sourceLocation)
            #expect(workspaces[indices[0]].id == group.anchorWorkspaceID, sourceLocation: sourceLocation)
        }
    }

    private func assertPinnedTiersHold(
        _ workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenUnpinnedTopLevel = false
        var emittedGroups = Set<MobileWorkspaceGroupPreview.ID>()
        for workspace in workspaces {
            if let groupID = workspace.groupID, let group = groupsByID[groupID] {
                if emittedGroups.insert(groupID).inserted {
                    if group.isPinned {
                        #expect(!seenUnpinnedTopLevel, sourceLocation: sourceLocation)
                    } else {
                        seenUnpinnedTopLevel = true
                    }
                    assertGroupMemberPinnedTier(workspaces, group: group, sourceLocation: sourceLocation)
                }
            } else if workspace.isPinned {
                #expect(!seenUnpinnedTopLevel, sourceLocation: sourceLocation)
            } else {
                seenUnpinnedTopLevel = true
            }
        }
    }

    private func assertGroupMemberPinnedTier(
        _ workspaces: [MobileWorkspacePreview],
        group: MobileWorkspaceGroupPreview,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let members = workspaces.filter { $0.groupID == group.id }
        guard let anchor = members.first else { return }
        #expect(anchor.id == group.anchorWorkspaceID, sourceLocation: sourceLocation)
        var seenUnpinned = false
        for member in members.dropFirst() {
            if member.isPinned {
                #expect(!seenUnpinned, sourceLocation: sourceLocation)
            } else {
                seenUnpinned = true
            }
        }
    }
}
