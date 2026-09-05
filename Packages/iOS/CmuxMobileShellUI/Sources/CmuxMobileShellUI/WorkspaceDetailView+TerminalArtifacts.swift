#if os(iOS)
import CmuxAgentChatUI
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

extension WorkspaceDetailView {
    var terminalArtifactFilesPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceDetail(.terminalArtifactFiles),
            fallback: $isTerminalArtifactFilesPresented
        )
    }

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
        terminalPresentationIsActive: scenePhase == .active,
        // Do not let a terminal reattach steal focus while the
        // composer owns or intentionally withholds the keyboard.
        autoFocusOnWindowAttach: shouldAutoFocus,
        isComposerActive: store.isComposerPresented,
        terminalTheme: store.activeTerminalTheme,
        topContentInset: terminalSurfaceTopContentInset,
        terminalConfigTheme: store.activeTerminalConfigTheme,
        // Drives the live recolor: when the synced theme changes the
        // shell bumps this, and the representable rebuilds the runtime
        // config + recolors the mounted surface in place (background,
        // letterbox, default cell colors) without a remount, so
        // scrollback survives a theme change.
        configThemeGeneration: store.terminalConfigThemeGeneration,
        artifactFilesEnabled: store.supportsTerminalArtifacts,
        terminalFolderTapEnabled: terminalFolderTapEnabled,
        terminalFilesChipEnabled: isTerminalFilesChipEnabled,
        showMissingFiles: showMissingFiles,
        sessionArtifactCountEnabled: store.supportsChatArtifactGallery,
        visibleArtifactCount: visibleArtifactCount,
        onArtifactFilesRequested: { anchor in
            store.recordAppEvent(
                .terminalArtifactGalleryOpened,
                correlationID: terminalID
            )
            terminalArtifactFilesPresentation.present {
                terminalArtifactFilesContext = TerminalArtifactContext(
                    workspaceID: workspace.id.rawValue,
                    surfaceID: terminalID,
                    anchor: anchor
                )
            }
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
        },
        onArtifactGalleryRefreshSignal: { signal in
            if artifactGalleryRefreshSignal != signal {
                artifactGalleryRefreshSignal = signal
            }
        }
    )
    .popover(
        isPresented: terminalArtifactFilesPresentation.isPresented,
        attachmentAnchor: .point(terminalArtifactFilesContext?.anchor ?? .bottom),
        arrowEdge: .bottom
    ) {
        Group {
            if let context = terminalArtifactFilesContext {
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
            }
        }
        .presentationCompactAdaptation(.sheet)
        .onDisappear {
            terminalArtifactFilesContext = nil
            terminalArtifactFilesPresentation.didDismiss()
        }
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
    .terminalKeyboardGeometryProbe("leaf-inside")
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(store.activeTerminalTheme.terminalBackgroundColor)
    // The surface positions its grid + docked toolbar from
    // `keyboardHeight` directly, so opt out of SwiftUI keyboard
    // avoidance; otherwise the view ALSO shrinks for the keyboard
    // and the reservation double-counts (extra gap when open).
    //
    // The CONTAINER bottom region must be ignored here too, in every
    // orientation: while the keyboard is up, the home-indicator band is
    // re-attributed from the keyboard region to the container region at
    // this node, so ignoring only the keyboard still shrank the surface by
    // that band on every toggle — which resized the terminal grid (a
    // shared-PTY renegotiation with the Mac) and retargeted the render
    // after the keyboard had settled. With the keyboard down the ancestors
    // already extend this view under the home indicator, so the extra
    // ignore changes nothing in the steady state.
    .ignoresSafeArea([.container, .keyboard], edges: .bottom)
    .terminalKeyboardGeometryProbe("leaf-outside")
    // Scroll-edge band (iOS 26): the surface underlaps the top bar so its
    // render-only overscan rows sit beneath the glass, giving the scroll
    // edge effect live content to blur. The grid itself stays below the
    // bar: the surface reserves `topContentInset` internally.
    .ignoresSafeArea(
        .container,
        edges: terminalScrollEdgeBandEnabled ? .top : []
    )
    // Captured OUTSIDE the top-edge ignore: once the leaf underlaps the
    // bar, geometry inside it (and the UIKit view) reads a zero top inset.
    .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.safeAreaInsets.top
    } action: { inset in
        if terminalCapturedTopInset != inset {
            terminalCapturedTopInset = inset
        }
    }
    // Keep the grid clear of the Dynamic Island and nav bar (pre-26 layout;
    // with the band on, the surface owns that clearance via the inset).
    .padding(.top, terminalScrollEdgeBandEnabled ? 0 : terminalTopPadding)
    }
}
#endif
