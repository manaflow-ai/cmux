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
/// ownership to the caller. No local command is installed in the pane. The same
/// insertion path serves a pane built for a live attachment session and an
/// optimistic pane reserved before the machine has created its terminal
/// (`Workspace+CloudTerminalReservation`).
@MainActor
extension Workspace {
    private static var cloudManualMirrorTabTitle: String {
        String(localized: "cloudTree.terminal.untitled", defaultValue: "terminal")
    }

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
        onFocus: @escaping @MainActor @Sendable () -> Void,
        attachment: CloudTerminalAttachmentStatus? = nil
    ) throws -> (workspaceID: UUID, panelID: UUID, surface: TerminalSurface) {
        guard let workspace = Self.liveWorkspace(id: destination.workspaceID),
              !workspace.isRetiredFromOwningTabManager else {
            throw SurfaceCatalogError.destinationNotFound(destination.workspaceID.uuidString)
        }
        let loading = workspace.cloudMachineLoadingPanel(at: destination, machineID: attachment?.machineID)
        guard let panel = workspace.makeRemoteTmuxPanePanel(
            id: loading?.id ?? UUID(),
            onInput: onInput,
            keyNameResolver: keyNameResolver
        ) else {
            throw SurfaceCatalogError.unsupported("manual cloud terminal panel")
        }
        Self.bindCloudManualMirrorCallbacks(
            panel: panel,
            onResize: onResize,
            onRuntimeReady: onRuntimeReady,
            onFocus: onFocus,
            attachment: attachment
        )
        if let loading {
            try workspace.adoptCloudMachineLoadingPanel(loading, terminal: panel, focus: focus)
            return (workspace.id, panel.id, panel.surface)
        }
        let panelID = try workspace.insertCloudManualMirrorPanel(panel, at: destination, focus: focus, isLoading: false)
        return (workspace.id, panelID, panel.surface)
    }

    /// Wires the session-facing surface callbacks a native cloud pane needs.
    /// The remote cmux-tui byte stream sends a replacement replay after every
    /// authoritative resize, so Ghostty may reflow the primary screen immediately
    /// and track its own bounds during the round trip.
    static func bindCloudManualMirrorCallbacks(
        panel: TerminalPanel,
        onResize: @escaping @MainActor @Sendable (TerminalSurfaceRawSizingSample) -> Void,
        onRuntimeReady: @escaping @MainActor @Sendable () -> Void,
        onFocus: @escaping @MainActor @Sendable () -> Void,
        attachment: CloudTerminalAttachmentStatus?
    ) {
        panel.surface.setManualIONoReflow(false)
        panel.surface.onManualSizeApplied = onResize
        panel.surface.onRuntimeReady = onRuntimeReady
        panel.surface.onManualWindowAttached = onRuntimeReady
        panel.onTerminalFocus = onFocus
        panel.cloudAttachment = attachment
    }

    /// Places an already-built manual-mirror panel at `destination` and returns its id.
    /// `isLoading` marks the tab strip while an optimistic pane waits for its terminal.
    func insertCloudManualMirrorPanel(
        _ panel: TerminalPanel,
        at destination: SurfaceDestination,
        focus: Bool,
        isLoading: Bool
    ) throws -> UUID {
        switch destination {
        case .workspace(_, let placement):
            let pane = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
            guard let pane else { throw SurfaceCatalogError.destinationNotFound("focused pane") }
            switch placement {
            case .tab:
                return try insertCloudManualMirrorTab(panel, in: pane, focus: focus, isLoading: isLoading)
            case .split:
                return try splitCloudManualMirrorPane(panel, target: pane, direction: .right, focus: focus, isLoading: isLoading)
            }
        case .tab(_, let paneID, _):
            guard let pane = Self.pane(paneID, in: self) else {
                throw SurfaceCatalogError.destinationNotFound("pane (paneID)")
            }
            return try insertCloudManualMirrorTab(panel, in: pane, focus: focus, isLoading: isLoading)
        case .split(_, let paneID, let direction):
            guard let pane = Self.pane(paneID, in: self) else {
                throw SurfaceCatalogError.destinationNotFound("pane (paneID)")
            }
            return try splitCloudManualMirrorPane(panel, target: pane, direction: direction, focus: focus, isLoading: isLoading)
        }
    }

    private func insertCloudManualMirrorTab(
        _ panel: TerminalPanel,
        in pane: PaneID,
        focus: Bool,
        isLoading: Bool
    ) throws -> UUID {
        panels[panel.id] = panel
        panelTitles[panel.id] = Self.cloudManualMirrorTabTitle
        guard let tab = bonsplitController.createTab(
            title: Self.cloudManualMirrorTabTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: panel.isDirty,
            isLoading: false,
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
        return panel.id
    }

    private func splitCloudManualMirrorPane(
        _ panel: TerminalPanel,
        target: PaneID,
        direction: SurfaceSplitDirection,
        focus: Bool,
        isLoading: Bool
    ) throws -> UUID {
        let previousPane = bonsplitController.focusedPaneId
        let previousTab = previousPane.flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
        panels[panel.id] = panel
        panelTitles[panel.id] = Self.cloudManualMirrorTabTitle
        let tab = Bonsplit.Tab(
            title: Self.cloudManualMirrorTabTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: panel.isDirty,
            isLoading: false,
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
        return panel.id
    }

    /// The live workspace with `id` in any window, or nil once it was retired.
    static func liveWorkspace(id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }

    private static func pane(_ rawID: String, in workspace: Workspace) -> PaneID? {
        guard let id = UUID(uuidString: rawID) else { return nil }
        return workspace.bonsplitController.allPaneIds.first { $0.id == id }
    }
}
