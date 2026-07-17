import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The workspace's surfaces, always visible and one tap away: tab chips
/// grouped by pane (mirroring the Mac's split structure), a layout-glyph map
/// button, and a new-tab button. Docked directly under the navigation bar.
/// Replaces the old top-right terminal picker menu.
struct SurfaceTabStrip: View {
    let snapshot: SurfaceNavigatorSnapshot
    let actions: SurfaceNavigatorActions

    private var palette: SurfaceNavigatorSnapshot.Palette { snapshot.palette }

    var body: some View {
        HStack(spacing: 8) {
            mapButton
            chipRows
            newTabButton
        }
        .padding(.horizontal, 10)
        .frame(height: SurfaceTabStripMetrics.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileSurfaceTabStrip")
    }

    private var mapButton: some View {
        Button(action: actions.openMap) {
            PaneLayoutGlyph(
                layout: snapshot.layout,
                selectedTabID: snapshot.selectedTabID,
                lineColor: palette.dimForeground.opacity(0.75),
                highlightColor: palette.foreground.opacity(0.9)
            )
            .frame(width: 20, height: 15)
            .frame(width: 32, height: 30)
            .background(palette.foreground.opacity(0.07), in: .rect(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(palette.foreground.opacity(0.12), lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("mobile.surfaces.map", defaultValue: "Workspace Map"))
        .accessibilityIdentifier("MobileSurfaceMapButton")
    }

    private var newTabButton: some View {
        Button {
            actions.newTab(snapshot.selectedPaneID)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.dimForeground)
                .frame(width: 32, height: 30)
                .background(palette.foreground.opacity(0.07), in: .rect(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(palette.foreground.opacity(0.12), lineWidth: 1)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("mobile.surfaces.newTab", defaultValue: "New Tab"))
        .accessibilityIdentifier("MobileSurfaceNewTabButton")
    }

    private var chipRows: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(snapshot.groups) { group in
                        SurfacePaneGroupView(
                            group: group,
                            showsPaneChrome: snapshot.groups.count > 1,
                            canCloseTab: snapshot.canCloseTab,
                            palette: palette,
                            actions: actions
                        )
                        .id(group.id.rawValue)
                    }
                }
                .padding(.vertical, 3)
            }
            .scrollIndicators(.hidden)
            .onChange(of: snapshot.selectedTabID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(chipAnchorID(newValue), anchor: .center)
                }
            }
            .onAppear {
                guard let selected = snapshot.selectedTabID else { return }
                proxy.scrollTo(chipAnchorID(selected), anchor: .center)
            }
        }
    }

    private func chipAnchorID(_ id: MobileTerminalPreview.ID) -> String {
        "surface-chip-\(id.rawValue)"
    }
}

/// Layout constants shared by the strip and the views that reserve space for it.
enum SurfaceTabStripMetrics {
    static let height: CGFloat = 42
}

/// One pane's chips. When the workspace has multiple panes, the group wears a
/// thin container so the pane boundaries read at a glance; a single unsplit
/// pane renders as a plain chip row.
private struct SurfacePaneGroupView: View {
    let group: SurfaceNavigatorSnapshot.PaneGroup
    let showsPaneChrome: Bool
    let canCloseTab: Bool
    let palette: SurfaceNavigatorSnapshot.Palette
    let actions: SurfaceNavigatorActions

    var body: some View {
        HStack(spacing: 3) {
            ForEach(group.chips) { chip in
                SurfaceTabChip(
                    chip: chip,
                    canCloseTab: canCloseTab,
                    palette: palette,
                    actions: actions
                )
                .id("surface-chip-\(chip.id.rawValue)")
            }
        }
        .padding(showsPaneChrome ? 3 : 0)
        .background {
            if showsPaneChrome {
                RoundedRectangle(cornerRadius: 12)
                    .fill(palette.foreground.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(palette.foreground.opacity(0.10), lineWidth: 1)
                    )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileSurfacePaneGroup-\(group.id.rawValue)")
    }
}

/// One tab chip: status dot (or kind icon), title, selection state.
private struct SurfaceTabChip: View {
    let chip: SurfaceNavigatorSnapshot.Chip
    let canCloseTab: Bool
    let palette: SurfaceNavigatorSnapshot.Palette
    let actions: SurfaceNavigatorActions

    var body: some View {
        Button {
            actions.selectTab(chip.id)
        } label: {
            HStack(spacing: 5) {
                leadingIndicator
                Text(chip.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(minWidth: 40, maxWidth: 128)
            .background(fillColor, in: .capsule)
            .overlay(Capsule().strokeBorder(strokeColor, lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            chip.isSelected ? palette.foreground : palette.dimForeground.opacity(0.9)
        )
        .contextMenu { contextMenuItems }
        .accessibilityIdentifier("MobileSurfaceChip-\(chip.id.rawValue)")
        .accessibilityLabel(chip.title)
        .accessibilityAddTraits(chip.isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch chip.kind {
        case .terminal:
            switch chip.status {
            case .working:
                Circle().fill(.green).frame(width: 6, height: 6)
            case .needsInput:
                Circle().fill(.orange).frame(width: 6, height: 6)
            case .none:
                EmptyView()
            }
        case .browser:
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .medium))
        case .other:
            Image(systemName: "square.dashed")
                .font(.system(size: 10, weight: .medium))
        }
    }

    private var fillColor: Color {
        chip.isSelected
            ? palette.foreground.opacity(0.17)
            : palette.foreground.opacity(0.055)
    }

    private var strokeColor: Color {
        if chip.status == .needsInput, !chip.isSelected {
            return .orange.opacity(0.55)
        }
        return palette.foreground.opacity(chip.isSelected ? 0.26 : 0.09)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if chip.kind == .terminal, canCloseTab {
            Button(role: .destructive) {
                actions.closeTab(chip.id)
            } label: {
                Label(
                    L10n.string("mobile.surfaces.closeTab", defaultValue: "Close Tab"),
                    systemImage: "xmark"
                )
            }
        }
    }
}
