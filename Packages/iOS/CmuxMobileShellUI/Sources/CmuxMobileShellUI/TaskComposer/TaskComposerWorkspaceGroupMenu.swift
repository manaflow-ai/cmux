#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A native menu row for choosing the destination group of a new workspace.
struct TaskComposerWorkspaceGroupMenu: View, Equatable {
    let groups: [MobileWorkspaceGroupPreview]
    let selectedWorkspaceGroupID: MobileWorkspaceGroupPreview.ID?
    let isSelectionPending: Bool
    let requiresSelectionResolution: Bool
    let isDisabled: Bool
    let select: (MobileWorkspaceGroupPreview.ID?) -> Void

    /// Default group glyph: grouped rectangles read as a parent holding
    /// children, unlike a folder, which collides with the Directory row.
    private static let defaultGroupSymbol = "rectangle.3.group"

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groups == rhs.groups
            && lhs.selectedWorkspaceGroupID == rhs.selectedWorkspaceGroupID
            && lhs.isSelectionPending == rhs.isSelectionPending
            && lhs.requiresSelectionResolution == rhs.requiresSelectionResolution
            && lhs.isDisabled == rhs.isDisabled
    }

    var body: some View {
        ZStack {
            TaskComposerRouteLabel(
                icon: .symbol(iconSymbol),
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
                    Image(systemName: selectedWorkspaceGroupID == nil ? "checkmark" : Self.defaultGroupSymbol)
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
                            : (group.iconSymbol ?? Self.defaultGroupSymbol))
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
            requiresSelectionResolution
                ? "mobile.taskComposer.workspaceGroup.recoveryHint"
                : "mobile.taskComposer.workspaceGroup.hint",
            defaultValue: requiresSelectionResolution
                ? "Choose another group or select None before submitting."
                : "Chooses where the new workspace appears on this Mac."
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
        if requiresSelectionResolution {
            return L10n.string(
                "mobile.taskComposer.workspaceGroup.unavailable",
                defaultValue: "Choose a group"
            )
        }
        return selectedGroup?.name ?? L10n.string(
            "mobile.taskComposer.workspaceGroup.none",
            defaultValue: "None"
        )
    }

    private var iconSymbol: String {
        if isSelectionPending { return "arrow.triangle.2.circlepath" }
        if requiresSelectionResolution { return "exclamationmark.triangle" }
        return selectedGroup?.iconSymbol ?? Self.defaultGroupSymbol
    }
}
#endif
