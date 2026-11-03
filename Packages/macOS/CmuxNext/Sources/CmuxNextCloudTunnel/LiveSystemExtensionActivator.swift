public import Foundation
import SystemExtensions

/// Submits real `OSSystemExtensionRequest` activation requests. Always replaces an older copy
/// (a classic nightly's, or the previous cmux build's), which also re-homes the System Settings
/// row to the running app, so it shows this app's name and icon.
@MainActor
public final class LiveSystemExtensionActivator: SystemExtensionActivating {
    /// Delegates must outlive their request; each is dropped when its stream finishes.
    private var delegates: [ObjectIdentifier: RequestDelegate] = [:]

    public init() {}

    public func activate(identifier: String) -> AsyncStream<SystemExtensionActivationEvent> {
        let (stream, continuation) = AsyncStream<SystemExtensionActivationEvent>.makeStream()
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        let delegate = RequestDelegate(continuation: continuation)
        let key = ObjectIdentifier(delegate)
        delegates[key] = delegate
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.delegates[key] = nil }
        }
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
        return stream
    }
}

/// Bridges one request's delegate callbacks (delivered on the main queue) to its stream.
private final class RequestDelegate: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    // Safe: the request was created with `queue: .main`, so every callback runs on the main
    // queue, one at a time; the continuation itself is Sendable.
    private let continuation: AsyncStream<SystemExtensionActivationEvent>.Continuation

    init(continuation: AsyncStream<SystemExtensionActivationEvent>.Continuation) {
        self.continuation = continuation
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        continuation.yield(.needsApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        continuation.yield(result == .willCompleteAfterReboot ? .willCompleteAfterReboot : .activated)
        continuation.finish()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        continuation.yield(.failed(error.localizedDescription))
        continuation.finish()
    }
}
