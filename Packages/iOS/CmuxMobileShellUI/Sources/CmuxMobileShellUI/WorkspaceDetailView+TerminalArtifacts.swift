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
        terminalTheme: store.activeTerminalTheme,
        terminalConfigTheme: store.activeTerminalConfigTheme,
        // Drives the live recolor: when the synced theme changes the
        // shell bumps this, and the representable rebuilds the runtime
        // config + recolors the mounted surface in place (background,
        // letterbox, default cell colors) without a remount, so
        // scrollback survives a theme change.
        configThemeGeneration: store.terminalConfigThemeGeneration,
        artifactFilesEnabled: store.supportsTerminalArtifacts,
        terminalFolderTapEnabled: terminalFolderTapEnabled,
        terminalFilesChipEnabled: terminalFilesChipEnabled,
        showMissingFiles: showMissingFiles,
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
                path: path,
                session: chosenChatSession
            )
        },
        onVisibleArtifactCountChanged: { count in
            if visibleArtifactCount != count {
                visibleArtifactCount = count
            }
        },
        onArtifactGalleryRefreshSignal: { signal in
            if artifactGalleryRefreshSignal != signal {
                artifactGalleryRefreshSignal = signal
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
            refreshSignal: artifactGalleryRefreshSignal,
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
    // `configThemeGeneration`), so remounting would only throw away scrollback
    // for no visual benefit.
    .id(terminalID)
    .onAppear {
        store.consumeTerminalAutoFocusSuppression(for: terminalID)
    }
    .onDisappear {
        visibleArtifactCount = 0
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(store.activeTerminalTheme.terminalBackgroundColor)
    // The surface positions its grid + docked toolbar from
    // `keyboardHeight` directly, so opt out of SwiftUI keyboard
    // avoidance; otherwise the view ALSO shrinks for the keyboard
    // and the reservation double-counts (extra gap when open).
    .ignoresSafeArea(.keyboard, edges: .bottom)
    // The surface's frame must be KEYBOARD-INVARIANT: with only the keyboard
    // inset ignored, the bottom edge respects the home indicator while the
    // keyboard is down but extends to the window bottom while it is up
    // (the keyboard region subsumes the indicator inset), so the frame
    // breathed by the indicator height on every transition and every
    // frame-relative keyboard conversion inside the surface was that much
    // off mid-animation (the bars visibly popped by it after each rise —
    // device forensics 2026-08-06). Extending under the indicator in ALL
    // states pins the frame; the dock's required safe-area cap keeps the
    // bars clear of the indicator while the keyboard is down.
    .ignoresSafeArea(.container, edges: .bottom)
    // Keep the grid clear of the Dynamic Island and nav bar.
    .padding(.top, terminalTopPadding)
    }
}
#endif
