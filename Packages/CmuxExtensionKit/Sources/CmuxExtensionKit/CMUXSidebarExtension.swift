import Foundation

public protocol CMUXSidebarExtension: Sendable {
    var manifest: CMUXExtensionManifest { get }

    func makeInitialSnapshot() async throws -> CMUXSidebarSnapshot
    func handle(_ action: CMUXSidebarAction) async throws -> CMUXExtensionActionResult
}

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
