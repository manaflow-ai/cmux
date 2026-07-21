import CmuxMobileBrowser
import CmuxMobileBrowserStream
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
        ZStack {
            detailContent()
                .opacity(surface == .terminal ? 1 : 0)
                .allowsHitTesting(surface == .terminal)
                .accessibilityHidden(surface != .terminal)
            if surface == .chat, let session = chosenChatSession {
                chatContent(session)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
            } else if surface == .browser, let browser = activeBrowser {
                browserContent(browser)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
            } else if surface == .browserStream, let browser = activeBrowserStream {
                browserStreamContent(browser)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
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
