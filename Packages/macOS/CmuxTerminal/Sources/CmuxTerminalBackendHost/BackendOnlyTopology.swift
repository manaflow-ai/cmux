public import CmuxTerminalBackend
internal import Foundation

/// The exact daemon-owned entities needed to open one visible terminal presentation.
public struct BackendOnlyTerminalSelection: Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let screenID: ScreenID
    public let paneID: PaneID
    public let surfaceID: SurfaceID
    public let numericSurfaceID: UInt64

    public init(
        workspaceID: WorkspaceID,
        screenID: ScreenID,
        paneID: PaneID,
        surfaceID: SurfaceID,
        numericSurfaceID: UInt64
    ) {
        self.workspaceID = workspaceID
        self.screenID = screenID
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.numericSurfaceID = numericSurfaceID
    }
}

public extension CanonicalWorkspace {
    /// Chooses the first terminal in canonical screen, pane, and tab order.
    /// Browser and unknown panel kinds stay daemon-owned but are not materialized
    /// by this terminal-only experiment.
    var backendOnlyFirstTerminal: BackendOnlyTerminalSelection? {
        for screen in screens {
            for pane in screen.panes {
                guard let surface = pane.tabs.first(where: { $0.kind == "terminal" }) else {
                    continue
                }
                return BackendOnlyTerminalSelection(
                    workspaceID: uuid,
                    screenID: screen.uuid,
                    paneID: pane.uuid,
                    surfaceID: surface.uuid,
                    numericSurfaceID: surface.id
                )
            }
        }
        return nil
    }
}
