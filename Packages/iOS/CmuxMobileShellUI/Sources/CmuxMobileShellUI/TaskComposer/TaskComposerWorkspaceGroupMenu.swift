#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A native menu row for choosing the destination group of a new workspace.
struct TaskComposerWorkspaceGroupMenu: View, Equatable {
    let groups: [MobileWorkspaceGroupPreview]
    let selectedWorkspaceGroupID: MobileWorkspaceGroupPreview.ID?
    let isSelectionPending: Bool
    let isDisabled: Bool
    let select: (MobileWorkspaceGroupPreview.ID?) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groups == rhs.groups
            && lhs.selectedWorkspaceGroupID == rhs.selectedWorkspaceGroupID
            && lhs.isSelectionPending == rhs.isSelectionPending
            && lhs.isDisabled == rhs.isDisabled
    }

    var body: some View {
        ZStack {
            TaskComposerRouteLabel(
                icon: .symbol(selectedGroup?.iconSymbol ?? "folder"),
                title: L10n.string(
                    "mobile.taskComposer.workspaceGroup",
                    defaultValue: "Workspace group"
                ),
                value: displayValue,
                valueFont: .caption.weight(.semibold),
                valueTruncationMode: .tail,
                chevronSystemName: "chevron.up.chevron.down"
            )
            .accessibilityHidden(true)

            Menu {
                Button {
                    select(nil)
                } label: {
                    Text(L10n.string(
                        "mobile.taskComposer.workspaceGroup.none",
                        defaultValue: "None"
                    ))
                    Image(systemName: selectedWorkspaceGroupID == nil ? "checkmark" : "folder")
                }

                if groups.isEmpty {
                    Button {} label: {
                        Text(L10n.string(
                            "mobile.taskComposer.workspaceGroup.empty",
                            defaultValue: "No workspace groups on this Mac"
                        ))
                        Image(systemName: "info.circle")
                    }
                    .disabled(true)
                } else {
                    ForEach(groups) { group in
                        Button {
                            select(group.id)
                        } label: {
                            Text(group.name)
                            Image(systemName: group.id == selectedWorkspaceGroupID
                                ? "checkmark"
                            : (group.iconSymbol ?? "folder"))
                        }
                    }
                }
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string(
            "mobile.taskComposer.workspaceGroup",
            defaultValue: "Workspace group"
        ))
        .accessibilityValue(displayValue)
        .accessibilityHint(L10n.string(
            "mobile.taskComposer.workspaceGroup.hint",
            defaultValue: "Chooses where the new workspace appears on this Mac."
        ))
        .accessibilityIdentifier("MobileTaskComposerWorkspaceGroup")
    }

    private var selectedGroup: MobileWorkspaceGroupPreview? {
        groups.first { $0.id == selectedWorkspaceGroupID }
    }

    private var displayValue: String {
        if isSelectionPending {
            return L10n.string(
                "mobile.taskComposer.workspaceGroup.loading",
                defaultValue: "Loading groups…"
            )
        }
        return selectedGroup?.name ?? L10n.string(
            "mobile.taskComposer.workspaceGroup.none",
            defaultValue: "None"
        )
    }
}
#endif
