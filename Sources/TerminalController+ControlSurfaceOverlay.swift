import CmuxControlSocket
import CmuxTerminalCore
import Foundation

extension TerminalController {
    func controlSurfaceOverlayStrings() -> ControlSurfaceOverlayStrings {
        ControlSurfaceOverlayStrings(
            tabManagerUnavailable: String(
                localized: "socket.surfaceOverlay.error.windowUnavailable",
                defaultValue: "cmux window is not available. Reopen the window and try again."
            ),
            workspaceNotFound: String(
                localized: "socket.surfaceOverlay.error.workspaceNotFound",
                defaultValue: "Workspace not found"
            ),
            surfaceNotFound: String(
                localized: "socket.surfaceOverlay.error.surfaceNotFound",
                defaultValue: "Surface not found"
            ),
            noFocusedSurface: String(
                localized: "socket.surfaceOverlay.error.noFocusedSurface",
                defaultValue: "No focused surface"
            ),
            surfaceNotTerminal: String(
                localized: "socket.surfaceOverlay.error.surfaceNotTerminal",
                defaultValue: "Surface is not a terminal"
            ),
            invalidIdentifier: String(
                localized: "socket.surfaceOverlay.error.invalidIdentifier",
                defaultValue: "Overlay id must start with a letter or number and use at most 128 letters, numbers, dots, dashes, underscores, or colons"
            ),
            emptyText: String(
                localized: "socket.surfaceOverlay.error.emptyText",
                defaultValue: "Overlay text cannot be empty"
            ),
            textTooLongFormat: String(
                localized: "socket.surfaceOverlay.error.textTooLongFormat",
                defaultValue: "Overlay text cannot exceed %lld UTF-8 bytes"
            ),
            invalidAnchorFormat: String(
                localized: "socket.surfaceOverlay.error.invalidAnchorFormat",
                defaultValue: "Unknown overlay anchor '%@'; use viewport, scrollback, or sticky"
            ),
            invalidAlignmentFormat: String(
                localized: "socket.surfaceOverlay.error.invalidPositionFormat",
                defaultValue: "Unknown overlay position '%@'; use left, center, or right"
            ),
            scrollbackUnavailable: String(
                localized: "socket.surfaceOverlay.error.scrollbackUnavailable",
                defaultValue: "Scrollback geometry is not available yet; retry after the terminal renders"
            )
        )
    }

    func controlSurfaceOverlay(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        action: ControlSurfaceOverlayAction
    ) -> ControlSurfaceOverlayResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }

        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = terminalPanel(
                in: dock,
                explicitSurfaceID: surfaceID,
                hasSurfaceIDParam: hasSurfaceIDParam,
                routing: routing
            )
            if target.invalidSurfaceID {
                return .surfaceNotFound
            }
            guard let resolvedSurfaceID = target.surfaceID else {
                return .noFocusedSurface
            }
            guard let terminalPanel = target.terminalPanel else {
                return dock.panels[resolvedSurfaceID] == nil
                    ? .surfaceNotFound
                    : .surfaceNotTerminal(resolvedSurfaceID)
            }
            return performControlSurfaceOverlay(
                action,
                panel: terminalPanel,
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                surfaceID: resolvedSurfaceID
            )
        }

        guard let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        if hasSurfaceIDParam, surfaceID == nil {
            return .surfaceNotFound
        }

        let resolvedSurfaceID: UUID
        let terminalPanel: TerminalPanel
        if let surfaceID {
            guard let target = workspace.controlSurfaceTarget(for: surfaceID) else {
                return .surfaceNotFound
            }
            guard let panel = target.panel as? TerminalPanel else {
                return .surfaceNotTerminal(target.surfaceID)
            }
            resolvedSurfaceID = target.surfaceID
            terminalPanel = panel
        } else {
            guard let target = workspace.controlDefaultTerminalTarget(paneID: routing.paneID) else {
                return .noFocusedSurface
            }
            resolvedSurfaceID = target.surfaceID
            terminalPanel = target.panel
        }

        return performControlSurfaceOverlay(
            action,
            panel: terminalPanel,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            surfaceID: resolvedSurfaceID
        )
    }

    private func performControlSurfaceOverlay(
        _ action: ControlSurfaceOverlayAction,
        panel: TerminalPanel,
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> ControlSurfaceOverlayResolution {
        switch action {
        case .list:
            return .listed(
                windowID: windowID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                overlays: panel.surface.terminalOverlays().map(controlSurfaceOverlaySnapshot)
            )

        case .set(let inputs):
            let request: TerminalOverlayRequest
            do {
                let anchor: TerminalOverlayRequestedAnchor = switch inputs.anchor {
                case .viewportTop: .viewportTop
                case .scrollbackTop: .scrollbackTop
                case .scrollbackSticky: .scrollbackSticky
                }
                request = try TerminalOverlayRequest(
                    id: inputs.id,
                    text: inputs.text,
                    anchor: anchor,
                    horizontalAlignment: terminalOverlayAlignment(inputs.alignment)
                )
            } catch let error as TerminalOverlayValidationError {
                return .validationFailed(controlSurfaceOverlayValidationError(error))
            } catch {
                return .validationFailed(.invalidIdentifier)
            }
            switch panel.surface.upsertTerminalOverlay(request) {
            case .success(let overlay):
                return .set(
                    windowID: windowID,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    overlay: controlSurfaceOverlaySnapshot(overlay)
                )
            case .failure(.scrollbackGeometryUnavailable):
                return .scrollbackUnavailable(surfaceID)
            }

        case .remove(let rawID):
            let id: String
            do {
                id = try TerminalOverlayRequest.validatedIdentifier(rawID)
            } catch {
                return .validationFailed(.invalidIdentifier)
            }
            return .removed(
                windowID: windowID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                overlayID: id,
                removed: panel.surface.removeTerminalOverlay(id: id)
            )

        case .clear:
            return .cleared(
                windowID: windowID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                removedCount: panel.surface.removeAllTerminalOverlays()
            )
        }
    }

    private func terminalOverlayAlignment(
        _ alignment: ControlSurfaceOverlayAlignment
    ) -> TerminalOverlayHorizontalAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }

    private func controlSurfaceOverlayValidationError(
        _ error: TerminalOverlayValidationError
    ) -> ControlSurfaceOverlayValidationError {
        switch error {
        case .invalidIdentifier:
            .invalidIdentifier
        case .emptyText:
            .emptyText
        case .textTooLong(let maxUTF8Bytes):
            .textTooLong(maxUTF8Bytes: maxUTF8Bytes)
        }
    }

    private func controlSurfaceOverlaySnapshot(
        _ overlay: TerminalOverlay
    ) -> ControlSurfaceOverlaySnapshot {
        let alignment: ControlSurfaceOverlayAlignment = switch overlay.horizontalAlignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        switch overlay.anchor {
        case .viewportTop:
            return ControlSurfaceOverlaySnapshot(
                id: overlay.id,
                text: overlay.text,
                anchor: .viewportTop,
                alignment: alignment
            )
        case .scrollback(let row, let rowSpaceRevision, let sticksToViewportTop):
            return ControlSurfaceOverlaySnapshot(
                id: overlay.id,
                text: overlay.text,
                anchor: sticksToViewportTop ? .scrollbackSticky : .scrollbackTop,
                alignment: alignment,
                scrollbackRow: row,
                rowSpaceRevision: rowSpaceRevision
            )
        }
    }
}
