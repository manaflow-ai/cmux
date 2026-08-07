import CmuxSettings
import Foundation

/// Allocates palette colors to workspaces that have no explicit color.
///
/// Every palette color is handed out once before any color repeats, so a user
/// with a normal number of workspaces sees a fully distinct set of rails. Once
/// the palette is exhausted the next workspace recycles the least-used color,
/// which keeps repeats spread evenly instead of clumping.
///
/// Allocation is deliberately *not* a hash of workspace identity. Independent
/// hashing double-books some colors while leaving others unused — with the
/// 16-color default palette and 8 workspaces there is an ~88% chance of a
/// duplicate rail, which defeats the point of the feature. Expanding the
/// palette does not fix this: the default colors already sit near the limit of
/// what stays distinguishable on a 3pt rail, so extra colors would only turn
/// "identical" into "looks identical".
///
/// Assignments are persisted by `WorkspaceAutoColorAssignmentStore`, so a
/// workspace keeps its color when other workspaces are created, reordered, or
/// deleted.
///
/// This type is deliberately free of AppKit/SwiftUI so the allocation rules
/// stay unit-testable; callers render the returned hex through
/// `WorkspaceTabColorSettings.displayNSColor(hex:colorScheme:forceBright:)`.
enum WorkspaceAutoTabColorAssignment {
    /// Picks the color for one newly assigned workspace.
    ///
    /// - Parameters:
    ///   - palette: Ordered palette entries, normally
    ///     `WorkspaceTabColorSettings.palette()`.
    ///   - usedHexes: Colors already spoken for, including both existing auto
    ///     assignments and manually chosen workspace colors. Manual colors are
    ///     included so an auto color does not duplicate a color the user picked
    ///     deliberately.
    /// - Returns: The least-used palette color, or `nil` for an empty palette.
    static func nextColorHex(
        palette: [WorkspaceTabColorEntry],
        usedHexes: [String]
    ) -> String? {
        guard !palette.isEmpty else { return nil }

        let paletteKeys = Set(palette.map { normalized($0.hex) })
        var counts: [String: Int] = [:]
        for hex in usedHexes {
            let key = normalized(hex)
            // A manual color outside the palette cannot use up a palette slot.
            guard paletteKeys.contains(key) else { continue }
            counts[key, default: 0] += 1
        }

        // Palette order breaks ties, so allocation is deterministic and the
        // first workspaces get the palette's leading colors.
        var best: WorkspaceTabColorEntry?
        var bestCount = Int.max
        for entry in palette {
            let count = counts[normalized(entry.hex)] ?? 0
            if count < bestCount {
                best = entry
                bestCount = count
            }
        }
        return best?.hex
    }

    /// Resolves the rail color for one workspace, applying the full enablement rule.
    ///
    /// Returns `nil` — leaving the rail hidden exactly as today — whenever the
    /// feature is off, the workspace already carries a manual color, the
    /// indicator style is not `leftRail`, or no color has been assigned.
    static func railColorHex(
        isEnabled: Bool,
        indicatorStyle: WorkspaceIndicatorStyle,
        customColorHex: String?,
        assignedColorHex: String?
    ) -> String? {
        guard isEnabled,
              indicatorStyle == .leftRail,
              customColorHex == nil else {
            return nil
        }
        return assignedColorHex
    }

    /// Case- and whitespace-insensitive key for comparing palette hexes.
    static func normalized(_ hex: String) -> String {
        hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
