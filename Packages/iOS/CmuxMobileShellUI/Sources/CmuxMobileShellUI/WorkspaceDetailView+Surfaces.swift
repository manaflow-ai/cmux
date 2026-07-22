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
            } else if case let .macSurface(macSurface) = surface {
                Group {
                    if macSurface.kind == .todo,
                       let todo = macSurface.todo,
                       store.supportsTodo(in: workspace.id) {
                        TodoSurfaceView(surface: macSurface, todo: todo) { mutation in
                            try await store.performTodoMutation(mutation, workspaceID: workspace.id)
                        }
                        .id(macSurface.id.rawValue)
                    } else {
                        SurfaceFallbackCardView(
                            surface: macSurface,
                            canOpenOnMac: store.supportsSurfaceFocus(in: workspace.id),
                            openOnMac: { [store, workspaceID = workspace.id, surfaceID = macSurface.id] in
                                await store.focusSurfaceOnMac(workspaceID: workspaceID, surfaceID: surfaceID)
                            }
                        )
                    }
                }
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
    #endif
}
