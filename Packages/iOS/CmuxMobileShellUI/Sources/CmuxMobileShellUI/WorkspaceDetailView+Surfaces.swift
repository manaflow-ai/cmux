import CMUXMobileCore
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
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
            if surface == .browser, let browser = activeBrowser {
                browserContent(browser)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
            } else if surface == .browser {
                waitingSurfacePlaceholder(
                    title: L10n.string("mobile.browser.waiting", defaultValue: "Waiting for Browser"),
                    detail: L10n.string(
                        "mobile.browser.waitingDetail",
                        defaultValue: "The browser will appear when the Mac is ready."
                    ),
                    symbol: "globe",
                    accessibilityIdentifier: "MobileBrowserPlaceholder"
                )
            } else if surface == .browserStream, let browser = activeBrowserStream {
                browserStreamContent(browser)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
            } else if surface == .browserStream {
                waitingSurfacePlaceholder(
                    title: L10n.string("mobile.browserStream.waiting", defaultValue: "Waiting for Browser"),
                    detail: L10n.string(
                        "mobile.browserStream.waitingDetail",
                        defaultValue: "The first frame will appear when the Mac is ready."
                    ),
                    symbol: "globe",
                    accessibilityIdentifier: "BrowserStreamPlaceholder"
                )
            } else if surface == .simulatorStream, let simulator = activeSimulatorStream {
                simulatorStreamContent(simulator)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
            } else if surface == .simulatorStream {
                waitingSurfacePlaceholder(
                    title: L10n.string("mobile.simulatorStream.waiting", defaultValue: "Waiting for Simulator"),
                    detail: L10n.string(
                        "mobile.simulatorStream.waitingDetail",
                        defaultValue: "The first frame will appear when the Mac is ready."
                    ),
                    symbol: "iphone",
                    accessibilityIdentifier: "SimulatorStreamPlaceholder"
                )
            } else if case let .macSurface(macSurface) = surface {
                macSurfaceContent(macSurface)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
                    // System colors, materials, and list backgrounds must
                    // resolve against the terminal theme the surface sits on,
                    // not the device appearance, or rows flash white over a
                    // dark theme (and vice versa).
                    .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
                    // Same recovery chrome as the terminal: the last synced
                    // surface stays visible underneath while the pill shows
                    // reconnect progress (it renders nothing when connected).
                    .overlay(alignment: .topLeading) {
                        MobileMacConnectionStatusPill(
                            host: host,
                            status: effectiveConnectionStatus,
                            reconnect: Self.reconnectAction(
                                connectionRequiresReauth: store.connectionRequiresReauth,
                                reconnect: { reconnectToWorkspaceMac() }
                            )
                        )
                        .padding(.top, 10)
                        .padding(.leading, 10)
                    }
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
    /// Kind → renderer dispatch for the selected non-terminal Mac surface.
    ///
    /// `MacSurfaceRenderer.resolve` owns the gating policy (capability +
    /// payload presence); unhandled kinds stay on the fallback card.
    @ViewBuilder
    func macSurfaceContent(_ macSurface: MobileSurfacePreview) -> some View {
        let renderer = MacSurfaceRenderer.resolve(
            surface: macSurface,
            supportsTodo: store.supportsTodo(in: workspace.id),
            supportsPanelArtifacts: store.supportsPanelArtifacts(in: workspace.id)
        )
        let openOnMac: () async -> Bool = { [store, workspaceID = workspace.id, surfaceID = macSurface.id] in
            await store.focusSurfaceOnMac(workspaceID: workspaceID, surfaceID: surfaceID)
        }
        let canOpenOnMac = store.supportsSurfaceFocus(in: workspace.id)
        switch renderer {
        case .todo(let todo):
            // The capability set empties while the connection recovers, so it
            // doubles as the "Mac can take mutations right now" signal; the
            // snapshot itself stays rendered either way.
            TodoSurfaceView(
                surface: macSurface,
                todo: todo,
                allowsMutations: store.supportsTodo(in: workspace.id)
            ) { mutation in
                try await store.performTodoMutation(mutation, workspaceID: workspace.id)
            }
            .id(macSurface.id.rawValue)
        case .filePreview(let path):
            PanelFileSurfaceView(
                surface: macSurface,
                path: path,
                loader: panelArtifactLoader(
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    surfaceID: macSurface.id.rawValue
                ),
                connectionStatus: effectiveConnectionStatus
            )
            .id(macSurface.id.rawValue)
        case .markdown(let path):
            MarkdownSurfaceView(
                surface: macSurface,
                path: path,
                loader: panelArtifactLoader(
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    surfaceID: macSurface.id.rawValue
                ),
                connectionStatus: effectiveConnectionStatus
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
            onClose: { browserStore.closeBrowser(for: workspace.id.rawValue) },
            onDiagnosticEvent: { event in
                recordLocalBrowserDiagnostic(event, surfaceID: browser.id.rawValue)
            }
        )
        .id(browser.id.rawValue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recordLocalBrowserDiagnostic(
        _ event: BrowserSurfaceDiagnosticEvent,
        surfaceID: String
    ) {
        switch event {
        case .navigateStarted:
            store.recordAppEvent(.browserNavigateStarted, correlationID: surfaceID)
        case .navigateSucceeded:
            store.recordAppEvent(.browserNavigateSucceeded, correlationID: surfaceID)
        case .navigateFailed(let error):
            store.recordAppEvent(
                .browserNavigateFailed,
                correlationID: surfaceID,
                failure: DiagnosticFailureKind.classify(error)
            )
        case .backRequested:
            store.recordAppEvent(.browserBackRequested, correlationID: surfaceID)
        case .forwardRequested:
            store.recordAppEvent(.browserForwardRequested, correlationID: surfaceID)
        case .reloadRequested:
            store.recordAppEvent(.browserReloadRequested, correlationID: surfaceID)
        case .stopRequested:
            store.recordAppEvent(.browserStopRequested, correlationID: surfaceID)
        case .closed:
            store.recordAppEvent(.browserClosed, correlationID: surfaceID)
        }
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

    @ViewBuilder
    func simulatorStreamContent(_ simulator: MobileSimulatorStreamSurfaceState) -> some View {
        legacySimulatorStreamContent(simulator)
    }

    private func legacySimulatorStreamContent(
        _ simulator: MobileSimulatorStreamSurfaceState
    ) -> some View {
        SimulatorStreamPane(
            state: simulator,
            workspaceID: workspace.rpcWorkspaceID.rawValue,
            actions: SimulatorStreamSurfaceActions(
                pointer: { await store.sendMobileSimulatorPointer($0) },
                text: { await store.sendMobileSimulatorText($0) },
                button: { await store.sendMobileSimulatorButton($0) },
                coordinate: { panelID, x, y, mapping in
                    await store.recordMobileSimulatorCoordinate(
                        panelID: panelID,
                        x: x,
                        y: y,
                        mapping: mapping
                    )
                },
                frameDiagnostic: { panelID, state, sequence, payloadBytes in
                    await store.recordMobileSimulatorFrameDiagnostic(
                        panelID: panelID,
                        state: state,
                        sequence: sequence,
                        payloadBytes: payloadBytes
                    )
                },
                presentationStalled: { panelID in
                    await store.handleStaleMobileSimulatorStream(panelID: panelID)
                },
                presentationSucceeded: { panelID in
                    await store.mobileSimulatorFrameDidPresent(panelID: panelID)
                },
                inputDiagnostic: { panelID, state, kind, detail in
                    await store.recordMobileSimulatorInputDiagnostic(
                        panelID: panelID,
                        state: state,
                        kind: kind,
                        detail: detail
                    )
                }
            ),
            reconnect: { Task { await store.reconnectOrRefresh() } }
        )
        .id(simulator.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif
}
