import CMUXMobileCore
import CmuxAgentChatUI
import CmuxAgentGUIUI
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileTerminal
import SwiftUI

extension WorkspaceDetailView {
    /// The active browser surface for this workspace, when a browser pane is open.
    var activeBrowser: BrowserSurfaceState? {
        browserStore.activeBrowser(for: workspace.id.rawValue)
    }

    var activeSurface: WorkspaceActiveSurface {
        WorkspaceActiveSurface.derive(hasActiveBrowser: activeBrowser != nil)
    }

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
        .onChange(of: surface) { _, newSurface in
            if newSurface == .terminal {
                // The surface stayed mounted under the chrome, so no attach
                // autofocus fires on return; refocus explicitly.
                if let refocusTerminalID {
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
