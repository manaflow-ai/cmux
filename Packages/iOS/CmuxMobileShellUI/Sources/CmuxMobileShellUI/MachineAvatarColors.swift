import CmuxMobileShellModel
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The shared machine color palette: a deterministic gradient per owning Mac so a
/// computer and all of its workspaces read with the same color across the
/// workspace list and the Computers screen. The slot is derived in the model
/// (``MachineAvatarPalette``); this maps it to concrete SwiftUI colors. Keep the
/// entries visually distinct so adjacent Macs read apart.
///
struct MachineAvatarColors {
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
        let slot = MachineAvatarPalette(slotCount: palettes.count)
            .slot(machineID: machineID, fallbackID: fallbackID)
        return LinearGradient(colors: palettes[slot], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Resolve a Mac's avatar gradient honoring its user override first:
    /// `"palette:<n>"` picks a built-in swatch, `"#RRGGBB"` a custom solid color;
    /// otherwise fall back to the assigned color index, then the id hash.
    static func gradient(
        customColor: String?,
        fallbackIndex: Int?,
        machineID: String?,
        fallbackID: String
    ) -> LinearGradient {
        if let customColor, !customColor.isEmpty {
            if customColor.hasPrefix("palette:"),
               let n = Int(customColor.dropFirst("palette:".count)) {
                return gradient(index: n)
            }
            if let color = Color(hexString: customColor) {
                return LinearGradient(
                    colors: [color, color.opacity(0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        if let fallbackIndex { return gradient(index: fallbackIndex) }
        return gradient(machineID: machineID, fallbackID: fallbackID)
    }
}

extension Color {
    /// Parse a `#RGB` / `#RRGGBB` / `#RRGGBBAA` hex string. `nil` when malformed.
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch hex.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// `#RRGGBB` for a resolved color, for persisting a custom color pick.
    var hexString: String? {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func hexByte(_ component: CGFloat) -> String {
            let byte = min(255, max(0, Int((component * 255).rounded())))
            return "\(Self.hexDigits[byte >> 4])\(Self.hexDigits[byte & 0x0F])"
        }
        return "#\(hexByte(r))\(hexByte(g))\(hexByte(b))"
        #else
        return nil
        #endif
    }

    private static let hexDigits = Array("0123456789ABCDEF")
}
