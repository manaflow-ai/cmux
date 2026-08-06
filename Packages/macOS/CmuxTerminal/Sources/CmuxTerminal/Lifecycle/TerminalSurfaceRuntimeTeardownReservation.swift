import Foundation

/// Admission to one pending hibernation teardown in the bounded batch.
struct TerminalSurfaceRuntimeTeardownReservation: Equatable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}
