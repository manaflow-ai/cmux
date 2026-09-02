import CmuxTerminal
import GhosttyKit
import Foundation

/// The catalog-facing factory for native cloud terminal projections.
///
/// Keeping this entry point beside ``SurfacePaneFactory`` means cloud panes
/// honor the same tab/split/workspace destinations as every other resource,
/// while their panel construction remains in the workspace manual-mirror seam.
@MainActor
extension SurfacePaneFactory {
    /// Creates a manual-mirror terminal at `destination`.
    static func makeCloudManualMirrorPane(
        at destination: SurfaceDestination,
        focus: Bool,
        onInput: @escaping @Sendable (TerminalManualInput) -> Void,
        keyNameResolver: (@MainActor @Sendable (ghostty_input_key_s) -> String?)? = nil,
        onResize: @escaping @MainActor @Sendable (TerminalSurfaceRawSizingSample) -> Void,
        onRuntimeReady: @escaping @MainActor @Sendable () -> Void,
        onFocus: @escaping @MainActor @Sendable () -> Void
    ) throws -> (workspaceID: UUID, panelID: UUID, surface: TerminalSurface) {
        guard let workspace = AppDelegate.shared?.tabManagerFor(tabId: destination.workspaceID)?.tabs.first(where: { $0.id == destination.workspaceID }) else {
            throw SurfaceCatalogError.destinationNotFound(destination.workspaceID.uuidString)
        }
        return try workspace.addCloudManualMirrorPane(
            at: destination,
            focus: focus,
            onInput: onInput,
            keyNameResolver: keyNameResolver,
            onResize: onResize,
            onRuntimeReady: onRuntimeReady,
            onFocus: onFocus
        )
    }
}
