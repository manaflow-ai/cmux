import Foundation
import SystemExtensions

/// Activates the bundled network system extension through
/// `OSSystemExtensionManager`.
///
/// Activation is idempotent: an already-active identical extension completes
/// immediately, a newer build replaces the old one, and the first activation
/// on a Mac waits for the user to allow it in System Settings (surfaced through
/// `onNeedsUserApproval`, the request keeps waiting). macOS refuses to load
/// system extensions from apps outside the Applications folder; that and the
/// other system errors map to ``CloudTunnelError`` values the user can act on.
actor SystemExtensionActivator {
    private var pending: [UUID: SystemExtensionActivationDelegate] = [:]

    func activate(identifier: String, onNeedsUserApproval: @escaping @Sendable () -> Void) async throws {
        let requestID = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let delegate = SystemExtensionActivationDelegate(onNeedsUserApproval: onNeedsUserApproval) { [weak self] result in
                Task { await self?.finish(requestID) }
                continuation.resume(with: result)
            }
            pending[requestID] = delegate
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
            request.delegate = delegate
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(_ requestID: UUID) {
        pending[requestID] = nil
    }
}
