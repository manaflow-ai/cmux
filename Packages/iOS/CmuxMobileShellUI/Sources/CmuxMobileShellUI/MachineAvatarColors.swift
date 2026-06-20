import CmuxMobileShellModel
import SwiftUI

/// The shared machine color palette: a deterministic gradient per owning Mac so a
/// computer and all of its workspaces read with the same color across the
/// workspace list and the Computers screen. The slot is derived in the model
/// (``MachineAvatarPalette``); this maps it to concrete SwiftUI colors. Keep the
/// entries visually distinct so adjacent Macs read apart.
enum MachineAvatarColors {
    static let palettes: [[Color]] = [
        [Color.blue, Color.cyan],
        [Color.green, Color.teal],
        [Color.orange, Color.yellow],
        [Color.purple, Color.indigo],
        [Color.pink, Color.red],
        [Color.mint, Color.green],
        [Color.indigo, Color.blue],
        [Color.brown, Color.orange],
    ]

    /// The gradient for a DISTINCT machine color index (from
    /// ``MobileWorkspaceAggregation/machineColorIndex``), wrapping at the palette
    /// size. This is the preferred path in the aggregated list: distinct Macs get
    /// distinct colors instead of occasionally colliding on a shared hash slot.
    static func gradient(index: Int) -> LinearGradient {
        let slot = ((index % palettes.count) + palettes.count) % palettes.count
        return LinearGradient(colors: palettes[slot], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Fallback gradient keyed to a hash of `machineID` (or `fallbackID` when the
    /// machine is unknown). Used only where no assigned color index is available
    /// (a non-aggregated preview); the hash can collide, so prefer ``gradient(index:)``.
    static func gradient(machineID: String?, fallbackID: String) -> LinearGradient {
        let slot = MachineAvatarPalette.slot(
            machineID: machineID,
            fallbackID: fallbackID,
            slotCount: palettes.count
        )
        return LinearGradient(colors: palettes[slot], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
