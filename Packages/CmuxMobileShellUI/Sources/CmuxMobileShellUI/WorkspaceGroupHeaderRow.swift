import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A collapsible group-section header in the mobile workspace list.
///
/// Mirrors the Mac sidebar group header, which doubles as the group's anchor
/// workspace row: the leading disclosure chevron toggles collapse, while tapping
/// the name/body selects (and, in push navigation, opens) the anchor workspace.
/// The anchor is represented by this header and never rendered as a separate row,
/// so this split is what keeps the anchor's terminals reachable from the phone.
struct WorkspaceGroupHeaderRow: View {
    let group: MobileWorkspaceGroupPreview
    let navigationStyle: WorkspaceNavigationStyle
    /// Whether the anchor workspace is the current selection (sidebar style only).
    let isAnchorSelected: Bool
    /// Select (and, in push style, navigate to) the anchor workspace.
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    /// Toggle the group's collapsed state on the Mac. When `nil` (previews, or a
    /// Mac without the groups capability), the chevron renders without a tap
    /// action.
    let toggleCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?

    /// The leading disclosure chevron. Its own hit target, so tapping it only
    /// collapses/expands and never opens the anchor.
    private var chevron: some View {
        let image = Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())

        // `.isButton` only when there is an actual activation action: a passive
        // chevron (no `toggleCollapsed`) must not announce as a button VoiceOver
        // can press to no effect. The collapsed/expanded state stays readable
        // through the label either way.
        return Group {
            if let toggleCollapsed {
                Button {
                    toggleCollapsed(group.id, !group.isCollapsed)
                } label: {
                    image
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            } else {
                image
            }
        }
        .accessibilityLabel(
            group.isCollapsed
                ? L10n.string("mobile.workspaceGroup.expand.a11y", defaultValue: "Expand group")
                : L10n.string("mobile.workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
        )
        .accessibilityIdentifier("MobileWorkspaceGroupDisclosure-\(group.id.rawValue)")
    }

    /// The group name plus icon. Tapping it opens the anchor workspace, mirroring
    /// the desktop header whose body focuses the anchor.
    private var nameLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(group.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if group.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var anchorTarget: some View {
        switch navigationStyle {
        case .push:
            NavigationLink(value: group.anchorWorkspaceID) {
                nameLabel
            }
            .simultaneousGesture(TapGesture().onEnded {
                selectWorkspace(group.anchorWorkspaceID)
            })
        case .sidebar:
            Button {
                selectWorkspace(group.anchorWorkspaceID)
            } label: {
                nameLabel
            }
            .buttonStyle(.plain)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            chevron
            anchorTarget
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            // Sidebar style highlights the active anchor's header, mirroring the
            // desktop header background when its anchor is selected. Push style
            // has no persistent selection, so it stays clear.
            (navigationStyle == .sidebar && isAnchorSelected)
                ? Color.primary.opacity(0.08)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileWorkspaceGroupHeader-\(group.id.rawValue)")
    }
}
