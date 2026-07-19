#if os(iOS)
import CmuxAgentChatUI
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

extension WorkspaceDetailView {
    @ViewBuilder
    func terminalArtifactSurface(terminalID: String) -> some View {
    let shouldAutoFocus = activeSurface == .terminal
        && store.shouldAutoFocusTerminalSurface(terminalID)
        && !store.isComposerPresented
    GhosttySurfaceRepresentable(
        workspaceID: workspace.id.rawValue,
        surfaceID: terminalID,
        store: store,
        fontSize: MobileTerminalFontPreference.defaultSize,
        // Do not let a terminal reattach steal focus while the
        // composer owns or intentionally withholds the keyboard.
        autoFocusOnWindowAttach: shouldAutoFocus,
        isComposerActive: store.isComposerPresented,
        // Drives the live recolor: when the synced theme changes the
        // shell bumps this, and the representable rebuilds the runtime
        // config + recolors the mounted surface in place (background,
        // letterbox, default cell colors) without a remount, so
        // scrollback survives a theme change.
        themeGeneration: store.terminalThemeGeneration,
        artifactFilesEnabled: store.supportsTerminalArtifacts,
        sessionArtifactCountEnabled: store.supportsChatArtifactGallery,
        visibleArtifactCount: visibleArtifactCount,
        onArtifactFilesRequested: { anchor in
            terminalArtifactFilesContext = TerminalArtifactContext(
                workspaceID: workspace.id.rawValue,
                surfaceID: terminalID,
                anchor: anchor
            )
        },
        onArtifactPathTapped: { path in
            selectedTerminalArtifact = TerminalArtifactSelection(
                workspaceID: workspace.id.rawValue,
                surfaceID: terminalID,
                path: path
            )
        },
        onVisibleArtifactCountChanged: { count in
            if visibleArtifactCount != count {
                visibleArtifactCount = count
            }
        }
    )
    .popover(
        item: $terminalArtifactFilesContext,
        attachmentAnchor: .point(terminalArtifactFilesContext?.anchor ?? .bottom),
        arrowEdge: .bottom
    ) { context in
        TerminalArtifactFilesSheet(
            workspaceID: context.workspaceID,
            surfaceID: context.surfaceID,
            source: store.makeChatEventSource(),
            loader: terminalArtifactLoader(
                workspaceID: context.workspaceID,
                surfaceID: context.surfaceID
            )
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCompactAdaptation(.sheet)
    }
    // Identity must track the selected terminal. The representable's
    // coordinator binds its byte sink to the surfaceID at make time and
    // `updateUIView` is a no-op, so without a per-terminal id SwiftUI
    // reuses the first terminal's surface and the dropdown never switches.
    // Keying on terminalID tears down the old surface (unregistering its
    // sink via dismantleUIView) and builds the newly-selected one.
    //
    // The theme is NOT folded into the identity: a theme change recolors
    // the live surface in place (config rebuild + view recolor driven by
    // `themeGeneration`), so remounting would only throw away scrollback
    // for no visual benefit.
    .id(terminalID)
    .onAppear {
        store.consumeTerminalAutoFocusSuppression(for: terminalID)
    }
    .onDisappear {
        visibleArtifactCount = 0
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(TerminalPalette.background)
    // The surface positions its grid + docked toolbar from
    // `keyboardHeight` directly, so opt out of SwiftUI keyboard
    // avoidance; otherwise the view ALSO shrinks for the keyboard
    // and the reservation double-counts (extra gap when open).
    .ignoresSafeArea(.keyboard, edges: .bottom)
    // Keep the grid clear of the Dynamic Island and nav bar.
    .padding(.top, terminalTopPadding)
    }
}
#endif
