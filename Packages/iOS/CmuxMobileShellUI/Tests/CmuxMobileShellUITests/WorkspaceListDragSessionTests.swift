#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceListDragSessionTests {
    @Test func flatDragPreviewsTheFinalOrderAndCanReverseDirection() throws {
        let workspaces = ["a", "b", "c", "d"].map { workspace($0) }
        let items = workspaces.map {
            WorkspaceListTableItem.workspace($0.id, indented: false)
        }
        var session = try #require(
            WorkspaceListDragSession(
                items: items,
                workspaces: workspaces,
                groups: [],
                groupHasUnreadByID: [:],
                sourceTableRow: 1
            )
        )

        let movedDown = session.update(destinationTableRow: 3)
        #expect(movedDown)
        #expect(session.visualItems.map(\.id) == [
            "workspace.a", "workspace.c", "workspace.b", "workspace.d"
        ])
        #expect(
            session.commit
                == WorkspaceListDragSession.Commit(sourceOffset: 1, destination: 3)
        )

        let movedUp = session.update(destinationTableRow: 0)
        #expect(movedUp)
        #expect(session.visualItems.map(\.id) == [
            "workspace.b", "workspace.a", "workspace.c", "workspace.d"
        ])
        #expect(
            session.commit
                == WorkspaceListDragSession.Commit(sourceOffset: 1, destination: 0)
        )
    }

    @Test func returningToTheSourceGapRemovesThePendingCommit() throws {
        let workspaces = ["a", "b", "c"].map { workspace($0) }
        let items = workspaces.map {
            WorkspaceListTableItem.workspace($0.id, indented: false)
        }
        var session = try #require(
            WorkspaceListDragSession(
                items: items,
                workspaces: workspaces,
                groups: [],
                groupHasUnreadByID: [:],
                sourceTableRow: 1
            )
        )

        session.update(destinationTableRow: 3)
        let returned = session.update(destinationTableRow: 1)
        #expect(returned)
        #expect(session.visualItems.map(\.id) == items.map(\.id))
        #expect(session.commit == nil)
    }

    @Test func groupHeaderMovesItsWholeRenderedBlockDuringHover() throws {
        let firstGroupID = MobileWorkspaceGroupPreview.ID(rawValue: "first")
        let secondGroupID = MobileWorkspaceGroupPreview.ID(rawValue: "second")
        let workspaces = [
            workspace("a", groupID: firstGroupID),
            workspace("b", groupID: firstGroupID),
            workspace("c"),
            workspace("d", groupID: secondGroupID),
            workspace("e", groupID: secondGroupID)
        ]
        let groups = [
            group("first", anchor: "a"),
            group("second", anchor: "d")
        ]
        let items = tableItems(workspaces: workspaces, groups: groups)
        let source = try #require(
            items.firstIndex(where: { $0.id == "groupHeader.second" })
        )
        var session = try #require(
            WorkspaceListDragSession(
                items: items,
                workspaces: workspaces,
                groups: groups,
                groupHasUnreadByID: [:],
                sourceTableRow: source
            )
        )

        session.update(destinationTableRow: 0)

        #expect(session.visualItems.map(\.id) == [
            "groupHeader.second",
            "workspace.e",
            "groupFooter.second",
            "groupHeader.first",
            "workspace.b",
            "groupFooter.first",
            "workspace.c"
        ])
        #expect(
            session.commit
                == WorkspaceListDragSession.Commit(
                    sourceOffset: source,
                    destination: 0
                )
        )
    }

    @Test func workspaceJoiningAGroupIndentsBeforeDrop() throws {
        let groupID = MobileWorkspaceGroupPreview.ID(rawValue: "group")
        let workspaces = [
            workspace("anchor", groupID: groupID),
            workspace("member", groupID: groupID),
            workspace("root")
        ]
        let groups = [group("group", anchor: "anchor")]
        let items = tableItems(workspaces: workspaces, groups: groups)
        let source = try #require(
            items.firstIndex(where: { $0.id == "workspace.root" })
        )
        let member = try #require(
            items.firstIndex(where: { $0.id == "workspace.member" })
        )
        var session = try #require(
            WorkspaceListDragSession(
                items: items,
                workspaces: workspaces,
                groups: groups,
                groupHasUnreadByID: [:],
                sourceTableRow: source
            )
        )

        session.update(destinationTableRow: member)

        #expect(session.visualItems.map(\.id) == [
            "groupHeader.group",
            "workspace.root",
            "workspace.member",
            "groupFooter.group"
        ])
        let moved = try #require(
            session.visualItems.first(where: { $0.id == "workspace.root" })
        )
        #expect(moved.isIndentedWorkspace)
    }

    @Test func chromeNeverParticipatesInTheMoveIndexSpace() throws {
        let workspaces = ["a", "b", "c"].map { workspace($0) }
        let items: [WorkspaceListTableItem] = [.chrome(.macStatusRow)]
            + workspaces.map { .workspace($0.id, indented: false) }
        var session = try #require(
            WorkspaceListDragSession(
                items: items,
                workspaces: workspaces,
                groups: [],
                groupHasUnreadByID: [:],
                sourceTableRow: 2
            )
        )

        session.update(destinationTableRow: 4)

        #expect(session.visualItems.first?.id == "chrome.macStatusRow")
        #expect(
            session.commit
                == WorkspaceListDragSession.Commit(sourceOffset: 1, destination: 3)
        )
    }

    @Test func pinnedTierNormalizationIsVisibleBeforeRelease() throws {
        let workspaces = [
            workspace("pinned", isPinned: true),
            workspace("first"),
            workspace("second")
        ]
        let items = workspaces.map {
            WorkspaceListTableItem.workspace($0.id, indented: false)
        }
        var session = try #require(
            WorkspaceListDragSession(
                items: items,
                workspaces: workspaces,
                groups: [],
                groupHasUnreadByID: [:],
                sourceTableRow: 2
            )
        )

        session.update(destinationTableRow: 0)

        #expect(session.visualItems.map(\.id) == [
            "workspace.pinned",
            "workspace.second",
            "workspace.first"
        ])
    }

    @Test func cancellationRestoresTheExactBaselinePresentation() throws {
        let groupID = MobileWorkspaceGroupPreview.ID(rawValue: "group")
        let workspaces = [
            workspace("anchor", groupID: groupID),
            workspace("member", groupID: groupID),
            workspace("root")
        ]
        let groups = [group("group", anchor: "anchor")]
        let items = tableItems(workspaces: workspaces, groups: groups)
        var session = try #require(
            WorkspaceListDragSession(
                items: items,
                workspaces: workspaces,
                groups: groups,
                groupHasUnreadByID: [:],
                sourceTableRow: 3
            )
        )
        session.update(destinationTableRow: 1)

        let reset = session.resetPreview()

        #expect(reset)
        #expect(session.visualItems.map(\.id) == items.map(\.id))
        #expect(
            session.visualItems.map(\.isIndentedWorkspace)
                == items.map(\.isIndentedWorkspace)
        )
        #expect(session.commit == nil)
    }

    @Test func compatibilityTracksEveryMovePolicyInput() throws {
        let workspaces = [workspace("a"), workspace("b")]
        let items = workspaces.map {
            WorkspaceListTableItem.workspace($0.id, indented: false)
        }
        let session = try #require(
            WorkspaceListDragSession(
                items: items,
                workspaces: workspaces,
                groups: [],
                groupHasUnreadByID: [:],
                sourceTableRow: 0
            )
        )

        #expect(session.isCompatible(with: items, workspaces: workspaces, groups: []))

        var changedID = workspaces
        changedID[1].id = .init(rawValue: "replacement")
        #expect(!session.isCompatible(with: items, workspaces: changedID, groups: []))

        var changedGroup = workspaces
        changedGroup[1].groupID = .init(rawValue: "group")
        #expect(!session.isCompatible(with: items, workspaces: changedGroup, groups: []))

        var changedPinned = workspaces
        changedPinned[1].isPinned = true
        #expect(!session.isCompatible(with: items, workspaces: changedPinned, groups: []))

        let changedItems = [items[0], .workspace(.init(rawValue: "replacement"), indented: false)]
        #expect(!session.isCompatible(with: changedItems, workspaces: workspaces, groups: []))
    }

    private func workspace(
        _ id: String,
        groupID: MobileWorkspaceGroupPreview.ID? = nil,
        isPinned: Bool = false
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            isPinned: isPinned,
            groupID: groupID,
            terminals: []
        )
    }

    private func group(
        _ id: String,
        anchor: String
    ) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: id,
            anchorWorkspaceID: .init(rawValue: anchor)
        )
    }

    private func tableItems(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview]
    ) -> [WorkspaceListTableItem] {
        MobileWorkspaceListItem.items(
            workspaces: workspaces,
            groups: groups
        ).map { item in
            switch item {
            case .workspace(let workspace, let indented):
                .workspace(workspace.id, indented: indented)
            case .groupHeader(let group, _):
                .groupHeader(group.id)
            case .groupFooter(let groupID):
                .groupFooter(groupID)
            }
        }
    }
}
#endif
