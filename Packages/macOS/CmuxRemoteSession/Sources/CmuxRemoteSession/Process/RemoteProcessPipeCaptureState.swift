internal import Foundation

/// Process-local capture storage whose mutations are confined to the runner's
/// serial capture queue and read only after its capture group completes.
final class RemoteProcessPipeCaptureState: @unchecked Sendable {
    var stdoutData = Data()
    var stderrData = Data()
    var stdoutReadError: (any Error)?
    var stderrReadError: (any Error)?
}
