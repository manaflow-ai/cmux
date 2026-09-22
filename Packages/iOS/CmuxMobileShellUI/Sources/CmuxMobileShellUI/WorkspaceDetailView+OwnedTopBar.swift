#if os(iOS)
import CmuxMobileSupport
import SwiftUI

// MARK: - Workspace detail chrome

extension WorkspaceDetailView {
    private enum LeadingToolbarItem: Hashable, Identifiable {
        case sidebarToggle
        case backButton

        var id: Self { self }
    }

    private var ownedBarLeadingItems: [LeadingToolbarItem] {
        var items: [LeadingToolbarItem] = []
        if showsSidebarToggle, toggleSidebar != nil {
            items.append(.sidebarToggle)
        }
        if backButtonConfiguration != nil {
            items.append(.backButton)
        }
        return items
    }

    private enum TrailingToolbarItem: Hashable, Identifiable {
        case altScreenNotice
        case changes
        case terminalPicker

        var id: Self { self }
    }

    private var ownedBarTrailingItems: [TrailingToolbarItem] {
        var items: [TrailingToolbarItem] = []
        if altScreenNoticeIsVisible {
            items.append(.altScreenNotice)
        }
        if workspaceChangesAreAvailable {
            items.append(.changes)
        }
        items.append(.terminalPicker)
        return items
    }

    private var ownedBarTitleMaximumWidth: CGFloat {
        WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            leadingItemCount: ownedBarLeadingItems.count,
            trailingItemCount: ownedBarTrailingItems.count
        )
    }

    /// A stable detail bar for every iOS width. The system navigation bar may
    /// re-arbitrate toolbar items as a split sidebar changes width or a compact
    /// surface scrolls, which can move the terminal picker into `More`. This
    /// row stays in the detail column's layout and only changes its available
    /// title width.
    var workspaceOwnedTopBar: some View {
        HStack(spacing: 13) {
            ForEach(ownedBarLeadingItems) { item in
                switch item {
                case .sidebarToggle:
                    if let toggleSidebar {
                        WorkspaceSidebarToggleButton(action: toggleSidebar)
                    }
                case .backButton:
                    workspaceBackToolbarButton
                        .frame(minWidth: 17, minHeight: 22)
                        .ownedBarGlassButton()
                        .fixedSize()
                }
            }

            workspaceTitleMenu(
                maximumWidth: ownedBarTitleMaximumWidth
            )
                .ownedBarGlassButton()

            Spacer(minLength: 13)

            ownedBarTrailingCluster
                .fixedSize()
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .background(alignment: .top) {
            store.activeTerminalTheme.terminalBackgroundColor
                .ignoresSafeArea(edges: .top)
        }
        .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
        // Sidebar visibility is a layout transition, not a transition for the
        // controls themselves. Keep the trailing cluster anchored in place.
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var ownedBarTrailingCluster: some View {
        HStack(spacing: 15) {
            ForEach(ownedBarTrailingItems) { item in
                switch item {
                case .altScreenNotice:
                    AltScreenNoticeButton {
                        displaySettings.showAltScreenNotice = false
                    }
                case .changes:
                    WorkspaceChangesToolbarButton(
                        chip: workspaceChangesChip,
                        workspaceID: workspace.rpcWorkspaceID.rawValue,
                        action: openWorkspaceChanges
                    )
                    .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
                case .terminalPicker:
                    terminalPickerToolbarButton
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 44)
        .ownedBarGlassSurface()
    }
}

/// A single shared split-view action. Its owner moves between the sidebar
/// toolbar and the detail bar as the sidebar column changes, so both placements
/// have the same hit target and accessibility identity.
struct WorkspaceSidebarToggleButton: View {
    let action: () -> Void
    var usesSystemToolbarChrome = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel(
            L10n.string("mobile.sidebar.toggle", defaultValue: "Show or Hide Sidebar")
        )
        .accessibilityIdentifier("MobileSplitSidebarToggle")
        .ownedBarSidebarGlassButton(usesSystemToolbarChrome: usesSystemToolbarChrome)
        .fixedSize()
    }
}

private extension View {
    @ViewBuilder
    func ownedBarGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.plain)
                .frame(minHeight: WorkspaceRootToolbarSizing.controlHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: WorkspaceRootToolbarSizing.controlHeight)
                .background(.thinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func ownedBarSidebarGlassButton(usesSystemToolbarChrome: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.plain)
                .frame(
                    width: WorkspaceRootToolbarSizing.controlHeight,
                    height: WorkspaceRootToolbarSizing.controlHeight
                )
                .modifier(WorkspaceSidebarToolbarChromeModifier(
                    usesSystemToolbarChrome: usesSystemToolbarChrome
                ))
        } else if usesSystemToolbarChrome {
            self
                .buttonStyle(.plain)
                .frame(
                    width: WorkspaceRootToolbarSizing.controlHeight,
                    height: WorkspaceRootToolbarSizing.controlHeight
                )
        } else {
            self
                .buttonStyle(.plain)
                .frame(
                    minWidth: WorkspaceRootToolbarSizing.controlHeight,
                    minHeight: WorkspaceRootToolbarSizing.controlHeight
                )
                .background(.thinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func ownedBarGlassSurface() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(.thinMaterial, in: Capsule())
        }
    }
}

@available(iOS 26.0, *)
private struct WorkspaceSidebarToolbarChromeModifier: ViewModifier {
    let usesSystemToolbarChrome: Bool

    func body(content: Content) -> some View {
        if usesSystemToolbarChrome {
            content
        } else {
            content.glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
#endif
