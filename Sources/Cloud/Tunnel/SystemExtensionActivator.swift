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
    private var pending: [UUID: ActivationDelegate] = [:]

    func activate(identifier: String, onNeedsUserApproval: @escaping @Sendable () -> Void) async throws {
        let requestID = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let delegate = ActivationDelegate(onNeedsUserApproval: onNeedsUserApproval) { [weak self] result in
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

/// One activation request's delegate. Callbacks arrive on the main queue the
/// request was created with, so the single-use guard needs no lock; the
/// continuation resumes exactly once.
private final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private let onNeedsUserApproval: @Sendable () -> Void
    private let completion: @Sendable (Result<Void, any Error>) -> Void
    private var completed = false

    init(
        onNeedsUserApproval: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        self.onNeedsUserApproval = onNeedsUserApproval
        self.completion = completion
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onNeedsUserApproval()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            complete(.success(()))
        case .willCompleteAfterReboot:
            complete(.failure(CloudTunnelError.rebootRequired))
        @unknown default:
            complete(.success(()))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        complete(.failure(Self.userFacingError(for: error)))
    }

    private func complete(_ result: Result<Void, any Error>) {
        guard !completed else { return }
        completed = true
        completion(result)
    }

    /// Map system-extension errors to actions the user can take; the raw
    /// error stays in the log only.
    private static func userFacingError(for error: any Error) -> any Error {
        let nsError = error as NSError
        guard nsError.domain == OSSystemExtensionErrorDomain,
              let code = OSSystemExtensionError.Code(rawValue: nsError.code) else {
            return error
        }
        switch code {
        case .unsupportedParentBundleLocation:
            return CloudTunnelError.appNotInApplicationsFolder
        case .requestCanceled, .requestSuperseded:
            return CloudTunnelError.startFailed(String(
                localized: "cloudTunnel.error.activationCanceled",
                defaultValue: "The request to load the cmux Cloud Tunnel extension was canceled."
            ))
        case .authorizationRequired, .forbiddenBySystemPolicy:
            return CloudTunnelError.startFailed(String(
                localized: "cloudTunnel.error.activationNotAllowed",
                defaultValue: "macOS did not allow the cmux Cloud Tunnel extension to load. Allow it in System Settings › General › Login Items & Extensions, then retry."
            ))
        default:
            let format = String(
                localized: "cloudTunnel.error.activationFailed",
                defaultValue: "macOS could not load the cmux Cloud Tunnel extension (code %d)."
            )
            return CloudTunnelError.startFailed(String(format: format, nsError.code))
        }
    }
}
