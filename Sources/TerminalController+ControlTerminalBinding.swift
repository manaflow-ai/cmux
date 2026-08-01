import CmuxControlSocket
import CmuxTerminal
import Foundation
import GhosttyKit
import OSLog

/// Relationship between workspace-panel ownership and the canonical terminal
/// model used by socket I/O.
enum ControlTerminalSocketBindingState: String {
    case bound
    case registryRebound = "registry_rebound"
    case unavailable
}

/// One control-plane terminal destination after workspace ownership and live
/// runtime identity have been reconciled.
///
/// The workspace panel remains the structural owner (pane placement,
/// hibernation state, close/respawn), while `surface` is the process registry's
/// canonical runtime model for socket I/O. They are normally identical. A
/// replacement overlap can make them differ briefly; I/O follows the registry
/// instead of pinning itself to the outgoing panel wrapper.
@MainActor
struct ControlTerminalSocketTarget {
    nonisolated private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "socket.terminal-binding"
    )

    let surfaceID: UUID
    let panel: TerminalPanel
    let surface: TerminalSurface
    let bindingState: ControlTerminalSocketBindingState

    /// Sends socket text through the canonical surface while preserving the
    /// panel-owned hibernation resume path when both owners already agree.
    func sendInputResult(_ text: String) -> TerminalSurface.InputSendResult {
        if surface === panel.surface {
            return panel.sendInputResult(text)
        }
        return surface.sendInputResult(text)
    }

    /// Sends a named key through the canonical surface, retaining the panel's
    /// explicit-input resume behavior for an ordinary bound target.
    func sendNamedKeyResult(_ key: String) -> TerminalSurface.NamedKeySendResult {
        if surface === panel.surface {
            return panel.sendNamedKeyResult(key)
        }
        return surface.sendNamedKey(key)
    }

    /// Performs a Ghostty binding action against the canonical surface.
    func performBindingAction(_ action: String) -> Bool {
        guard surface.liveSurfaceForGhosttyAccess(
            reason: "socket.bindingAction"
        ) != nil else { return false }
        if surface === panel.surface {
            return panel.performBindingAction(action)
        }
        return surface.performExplicitInputBindingAction(action)
    }

    /// Requests a renderer refresh from the canonical surface.
    func forceRefresh(reason: String) {
        surface.forceRefresh(reason: reason)
    }
}

@MainActor
extension Workspace {
    /// Resolves an explicitly addressed workspace terminal for socket I/O.
    func controlSocketTerminalTarget(for requestedSurfaceID: UUID) -> ControlTerminalSocketTarget? {
        guard let owned = controlTerminalTarget(for: requestedSurfaceID) else { return nil }
        return ControlTerminalSocketTarget.resolve(
            surfaceID: owned.surfaceID,
            panel: owned.panel,
            workspaceID: id
        )
    }

    /// Resolves the pane-selected or focused workspace terminal for socket I/O.
    func controlDefaultSocketTerminalTarget(
        paneID: UUID?
    ) -> ControlTerminalSocketTarget? {
        guard let owned = controlDefaultTerminalTarget(paneID: paneID) else { return nil }
        return ControlTerminalSocketTarget.resolve(
            surfaceID: owned.surfaceID,
            panel: owned.panel,
            workspaceID: id
        )
    }
}

@MainActor
extension DockSplitStore {
    /// Resolves a structurally owned Dock terminal against the live registry.
    func controlSocketTerminalTarget(for surfaceID: UUID) -> ControlTerminalSocketTarget? {
        guard let panel = panels[surfaceID] as? TerminalPanel else { return nil }
        return ControlTerminalSocketTarget.resolve(
            surfaceID: surfaceID,
            panel: panel,
            workspaceID: workspaceId
        )
    }
}

@MainActor
private extension ControlTerminalSocketTarget {
    /// Reconciles app-owned topology with package-owned live runtime identity.
    static func resolve(
        surfaceID: UUID,
        panel: TerminalPanel,
        workspaceID: UUID
    ) -> ControlTerminalSocketTarget? {
        guard let canonical = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              canonical.tabId == workspaceID else {
            return nil
        }
        let state: ControlTerminalSocketBindingState = canonical === panel.surface
            ? .bound
            : .registryRebound
        if state == .registryRebound {
            logger.debug(
                "Rebound socket surface=\(surfaceID, privacy: .public) workspace=\(workspaceID, privacy: .public)"
            )
        }
        return ControlTerminalSocketTarget(
            surfaceID: surfaceID,
            panel: panel,
            surface: canonical,
            bindingState: state
        )
    }
}

extension TerminalController {
    /// Creates the health row shared by workspace and Dock surface listings.
    func controlSurfaceHealthEntry(
        for panel: any Panel,
        terminalTarget: ControlTerminalSocketTarget?
    ) -> ControlSurfaceHealthEntry {
        if let terminalPanel = panel as? TerminalPanel {
            return ControlSurfaceHealthEntry(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                inWindow: terminalTarget?.surface.isViewInWindow
                    ?? terminalPanel.surface.isViewInWindow,
                socketBindingRawValue: terminalTarget?.bindingState.rawValue
                    ?? ControlTerminalSocketBindingState.unavailable.rawValue
            )
        }
        let inWindow = (panel as? BrowserPanel).map { $0.webView.window != nil }
        return ControlSurfaceHealthEntry(
            surfaceID: panel.id,
            typeRawValue: panel.panelType.rawValue,
            inWindow: inWindow
        )
    }

    /// Captures terminal text from a validated canonical runtime model.
    func readTerminalTextRawSnapshot(
        terminalSurface: TerminalSurface,
        includeScrollback: Bool
    ) -> TerminalTextRawSnapshot? {
        guard terminalSurface.liveSurfaceForGhosttyAccess(
            reason: "socket.readTerminalText"
        ) != nil else { return nil }
        if includeScrollback {
            return TerminalTextRawSnapshot(
                viewport: nil,
                screen: readTerminalSelectionText(
                    terminalSurface: terminalSurface,
                    pointTag: GHOSTTY_POINT_SCREEN
                ),
                history: readTerminalSelectionText(
                    terminalSurface: terminalSurface,
                    pointTag: GHOSTTY_POINT_SURFACE
                ),
                active: readTerminalSelectionText(
                    terminalSurface: terminalSurface,
                    pointTag: GHOSTTY_POINT_ACTIVE
                )
            )
        }
        return TerminalTextRawSnapshot(
            viewport: readTerminalSelectionText(
                terminalSurface: terminalSurface,
                pointTag: GHOSTTY_POINT_VIEWPORT
            ),
            screen: nil,
            history: nil,
            active: nil
        )
    }

    /// Reads one Ghostty text region from an already validated surface model.
    private func readTerminalSelectionText(
        terminalSurface: TerminalSurface,
        pointTag: ghostty_point_tag_e
    ) -> String? {
        guard let surface = terminalSurface.surface else { return nil }
        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let pointer = text.text, text.text_len > 0 else { return "" }
        let rawData = Data(bytes: pointer, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }

    /// Encodes a panel-owned terminal snapshot for the legacy socket protocol.
    func readTerminalTextBase64(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String {
        readTerminalTextBase64(
            terminalSurface: terminalPanel.surface,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    /// Encodes a canonical terminal snapshot for the legacy socket protocol.
    func readTerminalTextBase64(
        terminalSurface: TerminalSurface,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String {
        guard terminalSurface.liveSurfaceForGhosttyAccess(
            reason: "readTerminalTextBase64"
        ) != nil else {
            return "ERROR: Terminal surface not found"
        }
        guard let snapshot = readTerminalTextRawSnapshot(
            terminalSurface: terminalSurface,
            includeScrollback: includeScrollback
        ) else {
            return "ERROR: Terminal surface not found"
        }
        switch Self.terminalTextPayload(
            from: snapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return "OK \(payload.base64)"
        case .failure(let error):
            return "ERROR: \(error.message)"
        }
    }
}
