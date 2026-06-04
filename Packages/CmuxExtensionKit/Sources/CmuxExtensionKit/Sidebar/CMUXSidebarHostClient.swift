import Foundation

@_spi(CmuxHostTransport)
/// Host-side callbacks used by the sidebar XPC bridge.
public struct CmuxSidebarHostClient: Sendable {
    /// Returns the latest host snapshot that should be sent to an extension.
    public var snapshot: @Sendable () async throws -> CmuxSidebarSnapshot

    /// Dispatches a sidebar action from an extension into CMUX.
    public var dispatch: @Sendable (CmuxSidebarAction) async throws -> CmuxSidebarActionResult

    /// Creates a host client from snapshot and action-dispatch closures.
    public init(
        snapshot: @escaping @Sendable () async throws -> CmuxSidebarSnapshot,
        dispatch: @escaping @Sendable (CmuxSidebarAction) async throws -> CmuxSidebarActionResult
    ) {
        self.snapshot = snapshot
        self.dispatch = dispatch
    }
}
