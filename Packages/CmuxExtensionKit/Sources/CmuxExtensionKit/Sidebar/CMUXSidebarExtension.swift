import Foundation

public protocol CMUXSidebarExtension: Sendable {
    var manifest: CMUXExtensionManifest { get }

    func makeInitialSnapshot() async throws -> CMUXSidebarSnapshot
    func handle(_ action: CMUXSidebarAction) async throws -> CMUXExtensionActionResult
}
