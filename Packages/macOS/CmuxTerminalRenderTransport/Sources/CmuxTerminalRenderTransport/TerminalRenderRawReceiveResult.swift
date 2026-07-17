internal import Foundation

/// Sendable output of one bounded blocking Mach receive operation.
struct TerminalRenderRawReceiveResult: Sendable {
    let status: Int32
    let machError: Int32
    let metadata: Data?
    let surfacePort: UInt32
    let senderProcessID: Int32
    let senderEffectiveUserID: UInt32
}
