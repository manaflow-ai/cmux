import Foundation

/// Owns refresh requests for one cloud provider.
@MainActor
final class CloudProviderRefreshCoordinator {
    func refresh(force: Bool, operation: @escaping @MainActor (Bool) async -> Bool) async -> Bool {
        await operation(force)
    }

    func invalidate() {}
    func cancel() {}
}
