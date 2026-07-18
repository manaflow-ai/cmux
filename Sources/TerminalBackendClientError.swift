import CmuxTerminalBackend
import CmuxTerminalBackendService

/// Fail-closed errors surfaced by the process-wide backend client.
enum TerminalBackendClientError: Error, Equatable, Sendable {
    case disabled
    case requiresApproval
    case missingBundleItem(BackendServiceMissingBundleItem)
    case serviceNotFound
    case unavailable
    case reconnectExhausted(String)
    case authorityChanged(expected: BackendAuthority, actual: BackendAuthority)
    case unsupportedMutation
    case presentationUnavailable
    case rendererNotReady
}
