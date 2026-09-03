import Foundation
import SystemExtensions

/// One activation request's delegate. Callbacks arrive on the main queue the
/// request was created with, so the single-use guard needs no lock; the
/// continuation resumes exactly once.
final class SystemExtensionActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
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
