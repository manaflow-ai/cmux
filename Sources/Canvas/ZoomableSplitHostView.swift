import CmuxFoundation
import CmuxSettingsUI
import SwiftUI

/// Hosts the packed Bonsplit tree inside a single zoomable AppKit viewport.
///
/// Bonsplit remains the source of truth for pane placement. This wrapper only
/// changes the viewport around the split tree: pan/zoom/reveal/overview operate
/// on the whole packed layout as one document.
struct ZoomableSplitHostView: NSViewRepresentable {
    let workspace: Workspace
    let isWorkspaceInputActive: Bool
    let content: AnyView
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent
    @Environment(\.settingsRuntime) private var settingsRuntime
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var notificationStore: TerminalNotificationStore

    private var bridgedContent: AnyView {
        AnyView(
            content
                .environment(\.colorScheme, colorScheme)
                .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
                .environment(\.settingsRuntime, settingsRuntime)
                .environmentObject(tabManager)
                .environmentObject(notificationStore)
                .environmentObject(notificationStore.sidebarUnread)
        )
    }

    func makeNSView(context: Context) -> ZoomableSplitRootView {
        ZoomableSplitRootView(
            workspace: workspace,
            isWorkspaceInputActive: isWorkspaceInputActive,
            content: bridgedContent
        )
    }

    func updateNSView(_ nsView: ZoomableSplitRootView, context: Context) {
        nsView.update(
            isWorkspaceInputActive: isWorkspaceInputActive,
            content: bridgedContent
        )
    }

    static func dismantleNSView(_ nsView: ZoomableSplitRootView, coordinator: ()) {
        nsView.teardown()
    }
}
