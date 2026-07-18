import CmuxTerminal
import Foundation

/// One mutation admitted to a per-terminal FIFO before daemon execution.
struct TerminalBackendQueuedMutation: Equatable, Sendable {
    let sequence: UInt64
    let requestID: UUID
    let mutation: TerminalExternalRuntimeMutation
}
