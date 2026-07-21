import CMUXMobileCore
import CmuxAgentGUIUI
import CmuxMobileBrowser
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
        ZStack {
            detailContent()
                .opacity(surface == .terminal ? 1 : 0)
                .allowsHitTesting(surface == .terminal)
                .accessibilityHidden(surface != .terminal)
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
                    bottomChromeHeight: transcriptBottomChromeHeight,
                    bottomEdgeElementContainers: transcriptBottomEdgeElementContainers,
                    terminalTheme: store.activeTerminalTheme,
                    terminalThemeGeneration: store.terminalThemeGeneration,
                    density: displaySettings.transcriptDensity,
                    onShowTerminal: { guiModeSelected = false },
                    onShowActivity: { transcriptActivityDetails = $0 }
                )
                .ignoresSafeArea(.keyboard, edges: .bottom)
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
