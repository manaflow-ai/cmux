import CmuxMobileBrowser
import CmuxMobileShellModel
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
                macSurfaceContent(macSurface)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
                    // System colors, materials, and list backgrounds must
                    // resolve against the terminal theme the surface sits on,
                    // not the device appearance, or rows flash white over a
                    // dark theme (and vice versa).
                    .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
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
    /// Kind → renderer dispatch for the selected non-terminal Mac surface.
    ///
    /// `MacSurfaceRenderer.resolve` owns the gating policy (capability +
    /// payload presence); unhandled kinds stay on the fallback card.
    @ViewBuilder
    func macSurfaceContent(_ macSurface: MobileSurfacePreview) -> some View {
        let renderer = MacSurfaceRenderer.resolve(
            surface: macSurface,
            supportsTodo: store.supportsTodo(in: workspace.id),
            supportsPanelArtifacts: store.supportsPanelArtifacts
        )
        let openOnMac: () async -> Bool = { [store, workspaceID = workspace.id, surfaceID = macSurface.id] in
            await store.focusSurfaceOnMac(workspaceID: workspaceID, surfaceID: surfaceID)
        }
        let canOpenOnMac = store.supportsSurfaceFocus(in: workspace.id)
        switch renderer {
        case .todo(let todo):
            TodoSurfaceView(
                surface: macSurface,
                todo: todo,
                canOpenOnMac: canOpenOnMac,
                openOnMac: openOnMac
            ) { mutation in
                try await store.performTodoMutation(mutation, workspaceID: workspace.id)
            }
            .id(macSurface.id.rawValue)
        case .filePreview(let path):
            PanelFileSurfaceView(
                surface: macSurface,
                path: path,
                loader: panelArtifactLoader(
                    workspaceID: workspace.id.rawValue,
                    surfaceID: macSurface.id.rawValue
                ),
                canOpenOnMac: canOpenOnMac,
                openOnMac: openOnMac
            )
            .id(macSurface.id.rawValue)
        case .markdown(let path):
            MarkdownSurfaceView(
                surface: macSurface,
                path: path,
                loader: panelArtifactLoader(
                    workspaceID: workspace.id.rawValue,
                    surfaceID: macSurface.id.rawValue
                ),
                canOpenOnMac: canOpenOnMac,
                openOnMac: openOnMac
            )
            .id(macSurface.id.rawValue)
        case .fallbackCard:
            SurfaceFallbackCardView(
                surface: macSurface,
                workspaceName: workspace.name,
                canOpenOnMac: canOpenOnMac,
                openOnMac: openOnMac
            )
        }
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
