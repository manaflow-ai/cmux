#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite("Native workspace-list rows")
struct WorkspaceListNativeRowViewTests {
    @Test func workspaceRowExposesInteractiveChangesAndFitsItsContent() throws {
        let workspace = MobileWorkspacePreview(
            id: "workspace-1",
            name: "Build workspace",
            previewText: "Tests passed",
            terminals: []
        )
        var openedChanges = false
        let row = WorkspaceNativeRowView()
        row.configure(
            workspace: workspace,
            connectionStatus: .connected,
            isSelected: true,
            changes: MobileWorkspaceChangesChip(filesChanged: 2, additions: 8, deletions: 3),
            onOpenChanges: { openedChanges = true },
            wrapWorkspaceTitles: false,
            previewLineLimit: 2,
            unreadIndicatorLeftShift: 1.5,
            customizeOrRename: nil,
            customizeOrRenameTitle: nil,
            setPinned: nil
        )

        let chip = try #require(row.descendant(of: WorkspaceChangesChipNativeView.self))
        #expect(chip.accessibilityIdentifier == "MobileChangesChip-workspace-1")
        #expect(chip.accessibilityTraits.contains(.button))
        chip.sendActions(for: .primaryActionTriggered)
        #expect(openedChanges)

        let size = row.systemLayoutSizeFitting(
            CGSize(width: 330, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        #expect(size.width == 330)
        #expect(size.height >= 60)
    }

    @Test func groupHeaderSeparatesDisclosureFromAnchorSelection() throws {
        let group = MobileWorkspaceGroupPreview(
            id: "group-1",
            name: "Release",
            isCollapsed: false,
            anchorWorkspaceID: "workspace-1"
        )
        var selected: MobileWorkspacePreview.ID?
        var collapsed: Bool?
        let view = WorkspaceNativeGroupHeaderView()
        view.configure(
            value: WorkspaceGroupHeaderRowValue(
                group: group,
                hasUnread: true,
                navigationStyle: .push,
                isAnchorSelected: false,
                canCreateWorkspaceInGroup: true,
                canRenameGroup: true,
                canSetGroupPinned: true,
                canUngroupWorkspaceGroup: true,
                canDeleteWorkspaceGroup: true,
                canToggleCollapsed: true,
                unreadIndicatorLeftShift: 0
            ),
            actions: WorkspaceGroupHeaderRowActions(
                selectWorkspace: { selected = $0 },
                createWorkspaceInGroup: nil,
                renameGroup: nil,
                setGroupPinned: nil,
                ungroupWorkspaceGroup: nil,
                deleteWorkspaceGroup: nil,
                toggleCollapsed: { _, value in collapsed = value }
            )
        )

        let buttons = view.allDescendants.compactMap { $0 as? WorkspaceNativeActionButton }
        let disclosure = try #require(buttons.first {
            $0.accessibilityIdentifier == "MobileWorkspaceGroupDisclosure-group-1"
        })
        let anchor = try #require(buttons.first { $0 !== disclosure })

        disclosure.sendActions(for: .primaryActionTriggered)
        #expect(collapsed == true)
        #expect(selected == nil)

        anchor.sendActions(for: .primaryActionTriggered)
        #expect(selected?.rawValue == "workspace-1")
    }
}

private extension UIView {
    var allDescendants: [UIView] {
        subviews + subviews.flatMap(\.allDescendants)
    }

    func descendant<T: UIView>(of type: T.Type) -> T? {
        allDescendants.first { $0 is T } as? T
    }
}
#endif
