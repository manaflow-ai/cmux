import Foundation

struct TerminalSurfaceRuntimeOwnershipRecoveryEntry: Sendable {
    var action: TerminalSurfaceRuntimeOwnershipRecovery
    var failure: TerminalSurfaceRuntimeOwnershipRecoveryFailure
    var pendingFailureDeliveryID: UUID?
    var previousID: UUID?
    var nextID: UUID?
}
