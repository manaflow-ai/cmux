#if os(iOS)
import SwiftUI

// MARK: - Owned top bar

/// Self-laid-out replacement for the system navigation bar on the workspace
/// detail screen.
///
/// The system bar arbitrates per-item overflow with no public control below
/// iOS 27, which is how the trailing controls (and, over scrollable surfaces,
/// the whole bar) kept folding into a More "…" menu whenever a width estimate
/// undershot reality. Here the row is plain SwiftUI layout: the fixed pills
/// take their intrinsic width first, the title takes exactly the remainder
/// and truncates, and no overflow mechanism exists to trigger. The visual
/// language is unchanged: the same back pill, title menu, Changes chip, and
/// picker render inside the same Liquid Glass capsules the system drew, on
/// the same terminal-theme bar fill.
extension WorkspaceDetailView {
    var workspaceOwnedTopBar: some View {
        HStack(spacing: 13) {
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
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 3)
        .padding(.bottom, 3)
        .background(alignment: .top) {
            store.activeTerminalTheme.terminalBackgroundColor
                .ignoresSafeArea(edges: .top)
        }
        .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
    }

    /// The trailing controls share one glass capsule, matching how the
    /// system visually grouped the adjacent toolbar items.
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
                // The chrome sits on the terminal theme's background, not the
                // system scheme; resolve the counts' green/red for that.
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

// MARK: - Glass parity helpers

private extension View {
    /// Liquid Glass control chrome for a standalone bar button or menu,
    /// matching the capsule the system draws around toolbar items; material
    /// fallback below iOS 26 mirrors the pre-glass bar look.
    @ViewBuilder
    func ownedBarGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            self
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(.thinMaterial, in: Capsule())
        }
    }

    /// Liquid Glass surface for the grouped trailing cluster.
    @ViewBuilder
    func ownedBarGlassSurface() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(.thinMaterial, in: Capsule())
        }
    }
}
#endif
