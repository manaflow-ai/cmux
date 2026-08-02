import Foundation

/// Exclusive admission to one failure-isolated hibernation teardown slot.
struct TerminalSurfaceRuntimeTeardownReservation: Equatable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Ownership of one live or retained native Ghostty surface.
///
/// The reservation begins before `ghostty_surface_new` and ends only after
/// `ghostty_surface_free` returns. This bounds the combined live-surface and
/// teardown backlog even when every native-free worker is stalled.
struct TerminalSurfaceRuntimeOwnershipReservation: Equatable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}
