#if os(iOS)
import CmuxMobileSupport
import SwiftUI

// MARK: - Regular-width detail chrome

extension WorkspaceDetailView {
    /// A stable detail-column bar for iPad. The system navigation bar may
    /// re-arbitrate toolbar items as a split sidebar changes width, which makes
    /// the terminal picker animate out and back in. This row stays in the
    /// detail column's layout and only changes its available title width.
    var workspaceOwnedTopBar: some View {
        HStack(spacing: 13) {
            if showsSidebarToggle, let toggleSidebar {
                WorkspaceSidebarToggleButton(action: toggleSidebar)
            }

            if backButtonConfiguration != nil {
                workspaceBackToolbarButton
                    .frame(minWidth: 17, minHeight: 22)
                    .ownedBarGlassButton()
                    .fixedSize()
            }

            workspaceTitleMenu(usesNaturalWidth: true)
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
            if altScreenNoticeIsVisible {
                AltScreenNoticeButton {
                    displaySettings.showAltScreenNotice = false
                }
            }
            if workspaceChangesAreAvailable {
                WorkspaceChangesToolbarButton(
                    chip: workspaceChangesChip,
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    action: openWorkspaceChanges
                )
                .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
            }
            terminalPickerToolbarButton
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
