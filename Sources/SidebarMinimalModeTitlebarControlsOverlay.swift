import AppKit
import SwiftUI

/// Mounts the minimal-mode sidebar titlebar controls strip (sidebar toggle,
/// history, new workspace, notifications). Owns the presentation-mode and
/// titlebar debug-inset subscriptions so toggling minimal mode re-evaluates
/// only this overlay instead of the whole `VerticalTabsSidebar` body with its
/// O(N) workspace-row render context
/// (https://github.com/manaflow-ai/cmux/issues/5732).
struct SidebarMinimalModeTitlebarControlsOverlay: View {
    let observedWindow: NSWindow?
    let notificationStore: TerminalNotificationStore
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    let onFocusHistoryBack: () -> Void
    let onFocusHistoryForward: () -> Void

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
    private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
    private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var leadingInset: CGFloat {
        CGFloat(MinimalModeTitlebarDebugSettings.clamped(
            titlebarLeftControlsLeadingInset,
            range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
        ))
    }

    private var topPadding: CGFloat {
        // The debug top inset is read from defaults inside the frame helper;
        // the @AppStorage above exists so changing it still re-renders here.
        _ = titlebarLeftControlsTopInset
        guard let observedWindow else {
            return MinimalModeSidebarTitlebarControlsMetrics.topInset
        }
        return minimalModeSidebarTitlebarControlsTopInset(in: observedWindow)
    }

    var body: some View {
        if isMinimalMode {
            HiddenTitlebarSidebarControlsView(
                notificationStore: notificationStore,
                onToggleSidebar: onToggleSidebar,
                onToggleNotifications: { anchorView in
                    AppDelegate.shared?.toggleNotificationsPopover(
                        animated: true,
                        anchorView: anchorView
                    )
                },
                onNewTab: onNewTab,
                onFocusHistoryBack: onFocusHistoryBack,
                onFocusHistoryForward: onFocusHistoryForward
            )
            .padding(.leading, leadingInset)
            .padding(.top, topPadding)
        }
    }
}
