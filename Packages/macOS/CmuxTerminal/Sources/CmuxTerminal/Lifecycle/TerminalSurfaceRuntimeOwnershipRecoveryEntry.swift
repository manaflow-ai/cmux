import Foundation

struct TerminalSurfaceRuntimeOwnershipRecoveryEntry: Sendable {
    var action: TerminalSurfaceRuntimeOwnershipRecovery
    var previousID: UUID?
    var nextID: UUID?
}
