import Foundation

/// Submits one navigation per workspace to the app's existing operation owner.
@MainActor
protocol CloudTerminalNavigationScheduling: AnyObject {
    typealias Operation = @MainActor () async throws -> Void

    @discardableResult
    func start(key: String, _ operation: @escaping Operation) -> Bool
}
