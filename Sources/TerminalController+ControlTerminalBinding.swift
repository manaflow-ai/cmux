import CmuxTerminal
import Foundation
import GhosttyKit
import OSLog

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
    let surfaceID: UUID
    let panel: TerminalPanel
    let surface: TerminalSurface
    let bindingState: ControlTerminalSocketBindingState

    func sendInputResult(_ text: String) -> TerminalSurface.InputSendResult {
        if surface === panel.surface {
            return panel.sendInputResult(text)
        }
        return surface.sendInputResult(text)
    }

    func sendNamedKeyResult(_ key: String) -> TerminalSurface.NamedKeySendResult {
        if surface === panel.surface {
            return panel.sendNamedKeyResult(key)
        }
        return surface.sendNamedKey(key)
    }

    func performBindingAction(_ action: String) -> Bool {
        if surface === panel.surface {
            return panel.performBindingAction(action)
        }
        return surface.performExplicitInputBindingAction(action)
    }

    func forceRefresh(reason: String) {
        surface.forceRefresh(reason: reason)
    }
}

@MainActor
extension Workspace {
    func controlSocketTerminalTarget(for requestedSurfaceID: UUID) -> ControlTerminalSocketTarget? {
        guard let owned = controlTerminalTarget(for: requestedSurfaceID) else { return nil }
        return ControlTerminalSocketTarget.resolve(
            surfaceID: owned.surfaceID,
            panel: owned.panel,
            workspaceID: id
        )
    }

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
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
        category: "socket.terminal-binding"
    )

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
            logger.notice(
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
    func readTerminalTextRawSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool
    ) -> TerminalTextRawSnapshot? {
        readTerminalTextRawSnapshot(
            terminalSurface: terminalPanel.surface,
            includeScrollback: includeScrollback
        )
    }

    func readTerminalTextRawSnapshot(
        terminalSurface: TerminalSurface,
        includeScrollback: Bool
    ) -> TerminalTextRawSnapshot? {
        guard terminalSurface.surface != nil else { return nil }
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
