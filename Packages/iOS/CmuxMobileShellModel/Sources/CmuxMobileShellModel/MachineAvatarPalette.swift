import Foundation

/// Maps a workspace to a stable avatar color slot keyed to its OWNING MACHINE,
/// so every workspace on the same Mac shares one color in the aggregated
/// multi-Mac list. The UI layer maps a returned slot in `0..<slotCount` to a
/// concrete gradient; this stays free of SwiftUI so it is unit-testable.
///
public struct MachineAvatarPalette: Sendable {
    /// Default number of distinct color slots. The UI passes its real palette
    /// count so the slot is always in range.
    public static let defaultSlotCount = 8

    /// Number of distinct color slots in the target palette.
    public var slotCount: Int

    /// Create a palette slot resolver.
    public init(slotCount: Int = Self.defaultSlotCount) {
        self.slotCount = slotCount
    }

    /// Stable color slot for a workspace. Keyed to `machineID` so same-machine
    /// workspaces collide on one color by design; falls back to `fallbackID`
    /// (the workspace id) when the machine is unknown — e.g. a local single-Mac
    /// session before its device id resolves — so the avatar still has a stable
    /// color.
    public func slot(
        machineID: String?,
        fallbackID: String
    ) -> Int {
        let source = (machineID?.isEmpty == false) ? machineID! : fallbackID
        // djb2: spreads similar ids (UUID fragments, hostnames that share a
        // prefix) across distinct slots far better than a scalar sum, which
        // collides on anagram-like ids. `&*`/`&+` wrap intentionally; the
        // double-modulo below normalizes the (possibly negative) hash into range.
        var hash = 5381
        for scalar in source.unicodeScalars {
            hash = (hash &* 33) &+ Int(scalar.value)
        }
        let count = max(1, slotCount)
        return ((hash % count) + count) % count
    }
}
