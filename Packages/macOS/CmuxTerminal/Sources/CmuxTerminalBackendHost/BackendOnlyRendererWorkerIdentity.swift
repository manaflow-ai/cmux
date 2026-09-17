internal import CmuxTerminalBackend
internal import Darwin
internal import Foundation

struct BackendOnlyRendererWorkerIdentity: Hashable, Sendable {
    let daemonInstanceID: UUID
    let rendererEpoch: UInt64
    let processID: pid_t
    let effectiveUserID: UInt32
    let processInstanceToken: BackendRendererProcessInstanceToken
}
