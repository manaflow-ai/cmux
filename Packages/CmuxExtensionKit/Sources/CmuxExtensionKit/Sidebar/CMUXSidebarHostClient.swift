import Foundation

@_spi(CmuxHostTransport)
public struct CmuxSidebarHostClient: Sendable {
    public var snapshot: @Sendable () async throws -> CmuxSidebarSnapshot
    public var dispatch: @Sendable (CmuxSidebarAction) async throws -> CmuxSidebarActionResult

    public init(
        snapshot: @escaping @Sendable () async throws -> CmuxSidebarSnapshot,
        dispatch: @escaping @Sendable (CmuxSidebarAction) async throws -> CmuxSidebarActionResult
    ) {
        self.snapshot = snapshot
        self.dispatch = dispatch
    }
}
