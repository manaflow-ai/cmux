import Foundation

/// A bounded count snapshot of the terminal surface registry.
public struct TerminalSurfaceRegistryDiagnosticSnapshot: Equatable, Sendable {
    /// The number of live surface model objects still registered.
    public let registeredSurfaceCount: Int

    /// The number of registered surfaces hosted in normal workspace panes.
    public let workspaceSurfaceCount: Int

    /// The number of registered surfaces hosted in the right-sidebar dock.
    public let rightSidebarDockSurfaceCount: Int

    /// The number of native runtime surface pointers still owned by registered surfaces.
    public let runtimeSurfaceCount: Int

    /// Creates a diagnostic snapshot.
    ///
    /// - Parameters:
    ///   - registeredSurfaceCount: The number of live surface model objects.
    ///   - workspaceSurfaceCount: The number of workspace-hosted surfaces.
    ///   - rightSidebarDockSurfaceCount: The number of right-sidebar dock surfaces.
    ///   - runtimeSurfaceCount: The number of native runtime surface pointers.
    public init(
        registeredSurfaceCount: Int,
        workspaceSurfaceCount: Int,
        rightSidebarDockSurfaceCount: Int,
        runtimeSurfaceCount: Int
    ) {
        self.registeredSurfaceCount = registeredSurfaceCount
        self.workspaceSurfaceCount = workspaceSurfaceCount
        self.rightSidebarDockSurfaceCount = rightSidebarDockSurfaceCount
        self.runtimeSurfaceCount = runtimeSurfaceCount
    }

    /// Returns the JSON-compatible representation used by diagnostics and telemetry.
    public func payload() -> [String: Any] {
        [
            "registered_surface_count": registeredSurfaceCount,
            "workspace_surface_count": workspaceSurfaceCount,
            "right_sidebar_dock_surface_count": rightSidebarDockSurfaceCount,
            "runtime_surface_count": runtimeSurfaceCount
        ]
    }
}
