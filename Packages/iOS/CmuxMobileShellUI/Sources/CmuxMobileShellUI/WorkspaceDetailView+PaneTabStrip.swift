import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

#if os(iOS)
extension WorkspaceDetailView {
    /// Strip cards projected from this route's pane in current Mac order.
    var paneTabStripCards: [PaneTabStripCardSnapshot] {
        let chatTitle = L10n.string("mobile.workspace.agentChat", defaultValue: "Agent Chat")
        let chatCards = visibleChatSessions.compactMap { $0.paneChatCard(defaultTitle: chatTitle) }
        let localBrowser = browserStore.activeBrowser(for: workspace.id.rawValue).map {
            PaneLocalBrowserCardSnapshot(
                id: $0.id.rawValue,
                title: $0.title ?? L10n.string("mobile.browser.local.title", defaultValue: "iPhone Browser")
            )
        }
        return PaneTabStripProjection(
            layout: workspaceLayout,
            paneID: paneID,
            fallbackTerminals: workspace.terminals,
            chatCards: chatCards,
            localBrowser: localBrowser,
            attentionFirst: displaySettings.attentionShelfEnabled
        ).cards
    }

    var selectedPaneTabCardID: String? {
        if isChatMode, let pinnedChatSessionID { return "chat:\(pinnedChatSessionID)" }
        switch selectedBrowserSurface {
        case .local:
            guard let id = browserStore.activeBrowser(for: workspace.id.rawValue)?.id.rawValue else { return nil }
            return "local-browser:\(id)"
        case .mirrored(let surfaceID):
            return surfaceID
        case nil:
            return selectedTerminalID
        }
    }

    @ViewBuilder
    var paneTabStripChrome: some View {
        if paneTabStripVisibility.isStripVisible {
            PaneTabStripView(
                cards: paneTabStripCards,
                selectedCardID: selectedPaneTabCardID,
                attentionShelfEnabled: displaySettings.attentionShelfEnabled,
                connectionStatus: connectionStatus,
                supportsBrowserPreview: workspace.supportsBrowserPreview,
                previewUpdates: store.previewGridUpdates,
                browserPreviewUpdates: store.browserPreviewUpdates,
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

    private func selectTabFromStrip(_ card: PaneTabStripCardSnapshot) {
        switch card.kind {
        case .terminal:
            // A terminal-to-terminal strip switch should preserve the active
            // keyboard session. `selectTerminalCard` keeps the focused path
            // autofocusable and suppresses autofocus only when focus was
            // already elsewhere.
            selectTerminalCard(card.sourceID)
        case .mirroredBrowser:
            dismissTerminalKeyboardForChrome()
            isChatMode = false
            pinnedChatSessionID = nil
            selectedBrowserSurface = .mirrored(surfaceID: card.sourceID)
        case .localBrowser:
            dismissTerminalKeyboardForChrome()
            isChatMode = false
            pinnedChatSessionID = nil
            selectedBrowserSurface = .local
        case .agentChat:
            dismissTerminalKeyboardForChrome()
            guard let session = visibleChatSessions.first(where: { $0.id == card.sourceID }),
                  ensureChatConversationStore(for: session) != nil else { return }
            selectedBrowserSurface = nil
            if let terminalID = session.terminalID {
                store.selectTerminalFromChrome(.init(rawValue: terminalID))
            }
            pinnedChatSessionID = session.id
            isChatMode = true
        }
    }

    func selectInitialSurfaceIfNeeded() {
        guard !initialSurfaceSelectionApplied else { return }
        initialSurfaceSelectionApplied = true
        if workspaceLayout.flatMap({ tabKind(surfaceID: initialSurfaceID, in: $0.root) }) == .browser {
            selectedBrowserSurface = .mirrored(surfaceID: initialSurfaceID)
        } else {
            selectTerminalCard(initialSurfaceID)
        }
    }

    private func tabKind(
        surfaceID: String,
        in node: MobileWorkspaceLayoutNode
    ) -> MobileWorkspaceTabKind? {
        switch node {
        case .pane(let pane):
            return pane.tabs.first(where: { $0.id == surfaceID })?.kind
        case .split(let split):
            return tabKind(surfaceID: surfaceID, in: split.first)
                ?? tabKind(surfaceID: surfaceID, in: split.second)
        }
    }

    private func selectTerminalCard(_ surfaceID: String) {
        let target = MobileTerminalPreview.ID(rawValue: surfaceID)
        selectedBrowserSurface = nil
        isChatMode = false
        pinnedChatSessionID = nil
        guard target != store.selectedTerminalID else { return }
        if GhosttySurfaceView.isTerminalInputFocused {
            store.selectTerminal(target)
        } else {
            store.selectTerminalFromChrome(target)
        }
    }
}
#endif
