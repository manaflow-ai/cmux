import Foundation

public struct CMUXSidebarHostClient: Sendable {
    public var snapshot: @Sendable () async throws -> CMUXSidebarSnapshot
    public var dispatch: @Sendable (CMUXSidebarAction) async throws -> CMUXExtensionActionResult

    public init(
        snapshot: @escaping @Sendable () async throws -> CMUXSidebarSnapshot,
        dispatch: @escaping @Sendable (CMUXSidebarAction) async throws -> CMUXExtensionActionResult
    ) {
        self.snapshot = snapshot
        self.dispatch = dispatch
    }
}
