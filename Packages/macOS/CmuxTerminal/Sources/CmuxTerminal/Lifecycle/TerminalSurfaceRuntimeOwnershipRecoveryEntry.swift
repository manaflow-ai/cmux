import Foundation

struct TerminalSurfaceRuntimeOwnershipRecoveryEntry: Sendable {
    var action: TerminalSurfaceRuntimeOwnershipRecovery
    var failure: TerminalSurfaceRuntimeOwnershipRecoveryFailure
    var previousID: UUID?
    var nextID: UUID?
}
