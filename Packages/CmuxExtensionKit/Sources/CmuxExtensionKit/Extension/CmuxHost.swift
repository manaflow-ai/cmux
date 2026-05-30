import Foundation

/// Generic CMUX action channel available to extension UIs.
@MainActor
public struct CmuxHost: Sendable {
    private let performAction: @MainActor @Sendable (CMUXSidebarAction) async -> CMUXExtensionActionResult

    public init(
        perform: @escaping @MainActor @Sendable (CMUXSidebarAction) async -> CMUXExtensionActionResult
    ) {
        self.performAction = perform
    }

    public func createWorkspace(
        title: String? = nil,
        workingDirectory: String? = nil,
        select: Bool = true
    ) async -> CMUXExtensionActionResult {
        await performAction(.createWorkspace(title: title, workingDirectory: workingDirectory, select: select))
    }

    public func selectNextWorkspace() async -> CMUXExtensionActionResult {
        await performAction(.selectNextWorkspace)
    }

    public func selectPreviousWorkspace() async -> CMUXExtensionActionResult {
        await performAction(.selectPreviousWorkspace)
    }

    public func openURL(_ url: URL) async -> CMUXExtensionActionResult {
        await performAction(.openURL(url.absoluteString))
    }
}
