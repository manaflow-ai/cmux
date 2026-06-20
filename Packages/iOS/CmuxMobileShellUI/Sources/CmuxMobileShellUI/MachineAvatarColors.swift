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

    /// The gradient for a machine, keyed to `machineID` (falling back to
    /// `fallbackID` when the machine is unknown — e.g. a local single-Mac session
    /// before its device id resolves).
    static func gradient(machineID: String?, fallbackID: String) -> LinearGradient {
        let slot = MachineAvatarPalette.slot(
            machineID: machineID,
            fallbackID: fallbackID,
            slotCount: palettes.count
        )
        return LinearGradient(colors: palettes[slot], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
