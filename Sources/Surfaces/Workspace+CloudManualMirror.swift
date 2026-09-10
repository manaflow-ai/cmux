import AppKit
import Bonsplit
import CmuxTerminal
import CmuxWorkspaces
import Foundation
import GhosttyKit

/// Creates a native manual-mirror terminal at any catalog destination.
///
/// This is the shared pane-construction seam for cloud resources. It uses the
/// same configured panel path as remote-tmux mirrors, but leaves transport
/// ownership to the caller. No local command is installed in the pane.
@MainActor
extension Workspace {
    /// Inserts a manual-mirror terminal in `destination` and returns its native surface.
    ///
    /// - Parameters:
    ///   - destination: The catalog placement to honor.
    ///   - focus: Whether this user-initiated projection should focus the new pane.
    ///   - onInput: Ordered bytes/keys destined for the remote PTY.
    ///   - onResize: Called after Ghostty applies a local grid size.
    ///   - onRuntimeReady: Called after the native Ghostty runtime is ready.
    ///   - onFocus: Called when this projection receives terminal focus.
    /// - Returns: The workspace, panel, and surface created for the projection.
    func addCloudManualMirrorPane(
        at destination: SurfaceDestination,
        focus: Bool,
        onInput: @escaping @Sendable (TerminalManualInput) -> Void,
        keyNameResolver: (@MainActor @Sendable (ghostty_input_key_s) -> String?)? = nil,
        onResize: @escaping @MainActor @Sendable (TerminalSurfaceRawSizingSample) -> Void,
        onRuntimeReady: @escaping @MainActor @Sendable () -> Void,
        onFocus: @escaping @MainActor @Sendable () -> Void
    ) throws -> (workspaceID: UUID, panelID: UUID, surface: TerminalSurface) {
        guard let workspace = Self.workspace(for: destination.workspaceID),
              !workspace.isRetiredFromOwningTabManager else {
            throw SurfaceCatalogError.destinationNotFound(destination.workspaceID.uuidString)
        }
        switch destination {
        case .workspace(_, let placement):
            let pane = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first
            guard let pane else { throw SurfaceCatalogError.destinationNotFound("focused pane") }
            switch placement {
            case .tab:
                return try workspace.insertCloudManualMirrorTab(
                    in: pane,
                    focus: focus,
                    onInput: onInput,
                    keyNameResolver: keyNameResolver,
                    onResize: onResize,
                    onRuntimeReady: onRuntimeReady,
                    onFocus: onFocus
                )
            case .split:
                return try workspace.splitCloudManualMirrorPane(
                    target: pane,
                    direction: .right,
                    focus: focus,
                    onInput: onInput,
                    keyNameResolver: keyNameResolver,
                    onResize: onResize,
                    onRuntimeReady: onRuntimeReady,
                    onFocus: onFocus
                )
            }
        case .tab(_, let paneID, _):
            guard let pane = Self.pane(paneID, in: workspace) else {
                throw SurfaceCatalogError.destinationNotFound("pane (paneID)")
            }
            return try workspace.insertCloudManualMirrorTab(
                in: pane,
                focus: focus,
                onInput: onInput,
                keyNameResolver: keyNameResolver,
                onResize: onResize,
                onRuntimeReady: onRuntimeReady,
                onFocus: onFocus
            )
        case .split(_, let paneID, let direction):
            guard let pane = Self.pane(paneID, in: workspace) else {
                throw SurfaceCatalogError.destinationNotFound("pane (paneID)")
            }
            return try workspace.splitCloudManualMirrorPane(
                target: pane,
                direction: direction,
                focus: focus,
                onInput: onInput,
                keyNameResolver: keyNameResolver,
                onResize: onResize,
                onRuntimeReady: onRuntimeReady,
                onFocus: onFocus
            )
        }
    }

    private func insertCloudManualMirrorTab(
        in pane: PaneID,
        focus: Bool,
        onInput: @escaping @Sendable (TerminalManualInput) -> Void,
        keyNameResolver: (@MainActor @Sendable (ghostty_input_key_s) -> String?)? = nil,
        onResize: @escaping @MainActor @Sendable (TerminalSurfaceRawSizingSample) -> Void,
        onRuntimeReady: @escaping @MainActor @Sendable () -> Void,
        onFocus: @escaping @MainActor @Sendable () -> Void
    ) throws -> (workspaceID: UUID, panelID: UUID, surface: TerminalSurface) {
        guard let panel = makeRemoteTmuxPanePanel(
            onInput: onInput,
            keyNameResolver: keyNameResolver
        ) else {
            throw SurfaceCatalogError.unsupported("manual cloud terminal panel")
        }
        // The remote cmux-tui byte stream sends a replacement replay after
        // every authoritative resize. Allow Ghostty to reflow the primary
        // screen immediately so the native pane tracks its own bounds during
        // the round trip; the replay then supplies the remote canonical state.
        panel.surface.setManualIONoReflow(false)
        panel.surface.onManualSizeApplied = onResize
        panel.surface.onRuntimeReady = onRuntimeReady
        panel.surface.onManualWindowAttached = onRuntimeReady
        panel.onTerminalFocus = onFocus
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle
        guard let tab = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: panel.isDirty,
            isPinned: false,
            inPane: pane
        ) else {
            panels.removeValue(forKey: panel.id)
            panel.close()
            throw SurfaceCatalogError.unsupported("manual cloud terminal tab")
        }
        bindSurface(tab, toPanelId: panel.id)
        rememberTerminalConfigInheritanceSource(panel)
        panel.surface.flushPendingManualSizeReportIfAttached()
        if focus {
            focusPanel(panel.id)
        } else {
            panel.unfocus()
        }
        return (self.id, panel.id, panel.surface)
    }

    private func splitCloudManualMirrorPane(
        target: PaneID,
        direction: SurfaceSplitDirection,
        focus: Bool,
        onInput: @escaping @Sendable (TerminalManualInput) -> Void,
        keyNameResolver: (@MainActor @Sendable (ghostty_input_key_s) -> String?)? = nil,
        onResize: @escaping @MainActor @Sendable (TerminalSurfaceRawSizingSample) -> Void,
        onRuntimeReady: @escaping @MainActor @Sendable () -> Void,
        onFocus: @escaping @MainActor @Sendable () -> Void
    ) throws -> (workspaceID: UUID, panelID: UUID, surface: TerminalSurface) {
        let previousPane = bonsplitController.focusedPaneId
        let previousTab = previousPane.flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
        guard let panel = makeRemoteTmuxPanePanel(
            onInput: onInput,
            keyNameResolver: keyNameResolver
        ) else {
            throw SurfaceCatalogError.unsupported("manual cloud terminal panel")
        }
        panel.surface.setManualIONoReflow(false)
        panel.surface.onManualSizeApplied = onResize
        panel.surface.onRuntimeReady = onRuntimeReady
        panel.surface.onManualWindowAttached = onRuntimeReady
        panel.onTerminalFocus = onFocus
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle
        let tab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: panel.isDirty,
            isPinned: false
        )
        bindSurface(tab.id, toPanelId: panel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        let orientation: SplitOrientation = (direction == .left || direction == .right) ? .horizontal : .vertical
        let insertFirst = direction == .left || direction == .up
        guard bonsplitController.splitPane(
            target,
            orientation: orientation,
            withTab: tab,
            insertFirst: insertFirst
        ) != nil else {
            removeSurfaceMapping(forSurfaceId: tab.id)
            panels.removeValue(forKey: panel.id)
            panel.close()
            throw SurfaceCatalogError.unsupported("manual cloud terminal split")
        }
        rememberTerminalConfigInheritanceSource(panel)
        panel.surface.flushPendingManualSizeReportIfAttached()
        if focus {
            focusPanel(panel.id)
        } else if let previousPane {
            bonsplitController.focusPane(previousPane)
            if let previousTab { bonsplitController.selectTab(previousTab) }
            panel.unfocus()
        }
        return (self.id, panel.id, panel.surface)
    }

    private static func workspace(for id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }

    private static func pane(_ rawID: String, in workspace: Workspace) -> PaneID? {
        guard let id = UUID(uuidString: rawID) else { return nil }
        return workspace.bonsplitController.allPaneIds.first { $0.id == id }
    }
}
