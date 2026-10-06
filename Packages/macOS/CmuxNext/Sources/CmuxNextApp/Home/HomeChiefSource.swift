import Foundation

/// Which conversation Home's Chief tab shows (G6, brains/DESIGN-cmux-lawrence.md
/// section 6): the main conversation of the chief placed on a paired server
/// (a cloud conversation, answered by that server's brain) when the signed-in
/// user has one, else the local conversation with the local mux.
@MainActor
enum HomeChiefSource {
    /// The Chief tab's conversation: the placed chief's main conversation, else `local`.
    nonisolated static func choose(local: String?, placed: CloudChief?) -> String? {
        local  // red: not implemented yet
    }

    /// The placed chief (`CloudChiefs.placed`) with a main conversation, or
    /// nil: signed out, no chief placed, or the read failed (Home then keeps
    /// the local chief; a failure is logged by the caller, never shown).
    static func readPlaced(call: CloudChiefs.Call) async throws -> CloudChief? {
        nil  // red: not implemented yet
    }
}
