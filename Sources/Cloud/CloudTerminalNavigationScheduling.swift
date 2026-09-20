import Foundation

/// Submits one navigation per workspace to the app's existing operation owner.
@MainActor
protocol CloudTerminalNavigationScheduling: AnyObject {
    @discardableResult
    func start(key: String, _ operation: @escaping @MainActor () async throws -> Void) -> Bool
}
