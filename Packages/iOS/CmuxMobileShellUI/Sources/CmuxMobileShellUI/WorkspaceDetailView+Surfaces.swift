import CMUXMobileCore
import CmuxAgentChatUI
import CmuxAgentGUIUI
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileTerminal
import SwiftUI

extension WorkspaceDetailView {
    @ViewBuilder
    var detailSurfaceContent: some View {
        #if os(iOS)
        let surface = activeSurface
        // Captured at body time (the same evaluation as `shouldAutoFocus` in
        // `detailContent()`), so a chrome-driven terminal switch — which
        // suppresses the target's autofocus until the remount's `onAppear`
        // consumes the suppression — cannot race that consumption and pop
        // the keyboard anyway.
        let refocusTerminalID = WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: selectedTerminal?.id.rawValue,
            shouldAutoFocusTerminal: { store.shouldAutoFocusTerminalSurface($0) },
            isComposerPresented: store.isComposerPresented
        )
        WorkspaceDetailSurfaceStack(
            activeSurface: surface,
            isAgentGUIVisible: isAgentGUIVisible
        ) {
            detailContent()
        } overlays: {
            if surface == .browser, let browser = activeBrowser {
                browserContent(browser)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
            } else if surface == .browserStream, let browser = activeBrowserStream {
                browserStreamContent(browser)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
            }
            if isAgentGUIVisible,
               let engine = store.agentSyncEngine,
               let availability = agentGUIAvailability {
                TranscriptLiveView(
                    engine: engine,
                    sessionID: availability.sessionID,
                    terminalTheme: store.activeTerminalTheme,
                    terminalThemeGeneration: store.terminalThemeGeneration,
                    density: displaySettings.transcriptDensity,
                    draft: agentGUIDraftBinding(for: availability.sessionID),
                    artifactLoader: agentGUIArtifactLoader(sessionID: availability.sessionID.rawValue),
                    onShowTerminal: { guiModeSelected = false }
                )
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if workspaceChangesHint != nil {
                WorkspaceChangesHintBanner(
                    openChanges: openWorkspaceChanges,
                    dismiss: dismissWorkspaceChangesHint
                )
            }
        }
        .onChange(of: surface) { _, newSurface in
            if newSurface == .terminal {
                // The surface stayed mounted under the chrome, so no attach
                // autofocus fires on return; refocus explicitly. Never while
                // input is blocked: a disconnected terminal's keystrokes
                // drain silently, and the blocked observer won't re-fire to
                // resign a keyboard opened here.
                if let refocusTerminalID, !terminalInputIsBlocked {
                    GhosttySurfaceView.focusInput(surfaceID: refocusTerminalID)
                }
            } else {
                dismissTerminalKeyboardForChrome()
            }
        }
        #else
        detailContent()
        #endif
    }

    #if os(iOS)
    func agentGUIArtifactLoader(sessionID: String) -> ChatArtifactLoader {
        guard store.supportsChatArtifacts,
              let source = store.makeChatEventSource() else {
            return .unsupported(cache: terminalArtifactThumbnailCache)
        }
        return ChatArtifactLoader(
            source: source,
            sessionID: sessionID,
            cache: terminalArtifactThumbnailCache
        )
    }

    @ViewBuilder
    func browserContent(_ browser: BrowserSurfaceState) -> some View {
        MobileBrowserPane(
            state: browser,
            onClose: { browserStore.closeBrowser(for: workspace.id.rawValue) }
        )
        .id(browser.id.rawValue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func browserStreamContent(_ browser: BrowserStreamSurfaceState) -> some View {
        BrowserStreamPane(
            state: browser,
            actions: BrowserStreamSurfaceActions(
                pointer: { await store.sendMobileBrowserPointer($0) },
                scroll: { await store.sendMobileBrowserScroll($0) },
                key: { await store.sendMobileBrowserKey($0) },
                text: { await store.sendMobileBrowserText($0) },
                viewport: { parameters in
                    await browserStreamStore.reportBrowserStreamViewport(parameters)
                    await store.updateMobileBrowserViewport(parameters)
                },
                navigate: { await store.navigateMobileBrowser(panelID: $0, url: $1) },
                back: { await store.backMobileBrowser(panelID: $0) },
                forward: { await store.forwardMobileBrowser(panelID: $0) },
                reload: { await store.reloadMobileBrowser(panelID: $0) },
                respondToDialog: { await store.respondToMobileBrowserDialog($0) }
            ),
            reconnect: { Task { await store.reconnectOrRefresh() } }
        )
        .id(browser.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The browser-stream surface is conditionally mounted (not opacity
        // swapped like the terminal), so leaving it — via the surface picker
        // or nav back — removes this view and stops the stream here, replacing
        // the old in-bar close button.
        .onDisappear {
            browserStreamStore.deactivate(in: workspace.rpcWorkspaceID.rawValue)
            Task { await store.stopMobileBrowserStream(panelID: browser.id) }
        }
    }
    #endif
}

#if os(iOS)
/// Keeps the terminal surface at a stable structural position while browser or
/// Agent GUI chrome is presented above it. Hiding changes interaction and
/// accessibility only; the terminal-owned composer and toolbar stay mounted in
/// their original `GhosttySurfaceView` hierarchy.
struct WorkspaceDetailSurfaceStack<TerminalContent: View, OverlayContent: View>: View {
    let activeSurface: WorkspaceActiveSurface
    let isAgentGUIVisible: Bool
    private let terminalContent: TerminalContent
    private let overlayContent: OverlayContent

    init(
        activeSurface: WorkspaceActiveSurface,
        isAgentGUIVisible: Bool,
        @ViewBuilder terminal: () -> TerminalContent,
        @ViewBuilder overlays: () -> OverlayContent
    ) {
        self.activeSurface = activeSurface
        self.isAgentGUIVisible = isAgentGUIVisible
        terminalContent = terminal()
        overlayContent = overlays()
    }

    private var terminalIsPresented: Bool {
        activeSurface == .terminal && !isAgentGUIVisible
    }

    var body: some View {
        ZStack {
            terminalContent
                .opacity(terminalIsPresented ? 1 : 0)
                .allowsHitTesting(terminalIsPresented)
                .accessibilityHidden(!terminalIsPresented)
            overlayContent
        }
    }
}
#endif
