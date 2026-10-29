internal import CmuxCore
internal import Foundation

/// Runs the bounded `%C` expansion probe away from the coordinator queue.
///
/// Normal relay setup never needs this result. Recovery uses it only after
/// OpenSSH reports a binding conflict and requires an exact socket identity
/// before it can authorize a destructive inherited-master exit.
struct NativeSSHControlPathResolutionAttempt: Sendable {
    let request: RemoteProcessRequest
    let resolver: NativeSSHControlPathResolver
    let effectiveOptions: [String]
    let processRunner: any RemoteSessionProcessRunning

    /// Resolves the request's cmux-owned ControlPath, terminating it on task cancellation.
    @concurrent
    func run() async -> String? {
        let cancellation = RemoteProcessCancellationOperation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            do {
                let result = try processRunner.run(
                    request,
                    operation: cancellation
                )
                guard !Task.isCancelled,
                      result.status == 0 else {
                    return nil
                }
                return resolver.resolvedControlPath(
                    effectiveOptions: effectiveOptions,
                    sshConfigOutput: result.stdout
                )
            } catch {
                return nil
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
