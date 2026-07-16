import CmuxMobileBrowser
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
        let navigatorSnapshot = navigatorSnapshot
        VStack(spacing: 0) {
            // The surface strip stays visible across terminal/chat/browser
            // modes: switching tabs is always one tap away.
            SurfaceTabStrip(snapshot: navigatorSnapshot, actions: navigatorActions)
                .background(TerminalPalette.background)
            ZStack {
                detailContent()
                    .opacity(surface == .terminal ? 1 : 0)
                    .allowsHitTesting(surface == .terminal)
                    .accessibilityHidden(surface != .terminal)
                if surface == .chat, let session = chosenChatSession {
                    chatContent(session)
                        .background(TerminalPalette.background)
                } else if surface == .browser, let browser = activeBrowser {
                    browserContent(browser)
                        .background(TerminalPalette.background)
                }
            }
        }
        .overlay {
            // The workspace map: the zoomed-out, geometry-true pane/tab
            // overview. Overlays the whole detail so the zoom reads as the
            // terminal receding into its pane slot.
            if isWorkspaceMapPresented {
                WorkspaceMapView(
                    workspaceName: workspace.name,
                    snapshot: navigatorSnapshot,
                    openTab: { id in
                        withAnimation(.snappy(duration: 0.3)) {
                            isWorkspaceMapPresented = false
                        }
                        navigatorSelectTab(id)
                    },
                    fetchPreview: { id in
                        await store.fetchTerminalPreviewGrid(
                            workspaceID: workspace.id,
                            surfaceID: id.rawValue
                        )
                    },
                    dismiss: {
                        withAnimation(.snappy(duration: 0.3)) {
                            isWorkspaceMapPresented = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 1.06)))
                .zIndex(2)
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
