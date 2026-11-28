import Foundation

/// Exclusive admission to one failure-isolated hibernation teardown slot.
struct TerminalSurfaceRuntimeTeardownReservation: Equatable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}
