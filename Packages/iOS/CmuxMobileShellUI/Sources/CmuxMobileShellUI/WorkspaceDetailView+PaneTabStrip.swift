import CmuxMobileShellModel
import CmuxMobileTerminal
import SwiftUI

#if os(iOS)
extension WorkspaceDetailView {
    /// Strip cards projected from this route's pane in current Mac order.
    var paneTabStripCards: [PaneTabStripCardSnapshot] {
        PaneTabStripProjection(
            layout: workspaceLayout,
            paneID: paneID,
            fallbackTerminals: workspace.terminals,
            attentionFirst: displaySettings.attentionShelfEnabled
        ).cards
    }

    @ViewBuilder
    var paneTabStripChrome: some View {
        if paneTabStripVisibility.isStripVisible {
            PaneTabStripView(
                cards: paneTabStripCards,
                selectedSurfaceID: selectedTerminalID,
                attentionShelfEnabled: displaySettings.attentionShelfEnabled,
                connectionStatus: connectionStatus,
                previewUpdates: store.previewGridUpdates,
                select: selectTabFromStrip,
                toggleAttentionShelf: toggleAttentionShelf,
                createTerminal: createTerminalFromToolbar
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            PaneTabStripHandle(
                revealByTap: {
                    handlePaneTabStripEvent(.handleTapped)
                },
                revealByUpwardDrag: {
                    handlePaneTabStripEvent(.handleDraggedUp)
                }
            )
            .transition(.opacity)
        }
    }

    func handlePaneTabStripEvent(_ event: PaneTabStripVisibilityState.Event) {
        var next = paneTabStripVisibility
        next.handle(event)
        guard next != paneTabStripVisibility else { return }
        withAnimation(.snappy(duration: 0.22)) {
            paneTabStripVisibility = next
        }
    }

    private func toggleAttentionShelf() {
        displaySettings.attentionShelfEnabled.toggle()
    }

    private func selectTabFromStrip(_ surfaceID: String) {
        let target = MobileTerminalPreview.ID(rawValue: surfaceID)
        guard target != store.selectedTerminalID else { return }

        browserStore.closeBrowser(for: workspace.id.rawValue)
        isChatMode = false
        pinnedChatSessionID = nil

        // Preserve an already-visible terminal keyboard, while retaining the
        // chrome contract that a keyboard-down switch never summons one.
        if GhosttySurfaceView.isTerminalInputFocused {
            store.selectTerminal(target)
        } else {
            store.selectTerminalFromChrome(target)
        }
    }
}
#endif
