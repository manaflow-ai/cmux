import CmuxSettings
import Foundation

/// Allocates palette colors to workspaces that have no explicit color.
///
/// Every palette color is handed out once before any color repeats, so a user
/// with a normal number of workspaces sees a fully distinct set of rails. Among
/// equally-used colors the one that looks furthest from the colors already on
/// screen wins, so the first few workspaces get obviously different rails
/// instead of four shades of red. Once the palette is exhausted the next
/// workspace recycles the least-used color, which keeps repeats spread evenly
/// instead of clumping.
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
    /// A convenience over `WorkspaceAutoTabColorAllocator` for callers
    /// assigning exactly one workspace. Assigning several in a row should build
    /// one allocator and call `next()` repeatedly instead, so the palette
    /// bookkeeping is not rebuilt per workspace.
    ///
    /// - Parameters:
    ///   - palette: Ordered palette entries, normally
    ///     `WorkspaceTabColorSettings.palette()`.
    ///   - usedHexes: Colors already spoken for, including both existing auto
    ///     assignments and manually chosen workspace colors. Manual colors are
    ///     included so an auto color does not duplicate a color the user picked
    ///     deliberately.
    ///   - reservedHexes: Colors held for workspaces whose auto color is
    ///     currently hidden behind a manual one. These are still in `usedHexes`
    ///     — they count as used — but they are avoided while any other equally
    ///     used color exists, because taking one is the single duplicate that
    ///     can never be undone: the reservation comes back when the manual
    ///     color is cleared, and assignments are never rewritten afterwards.
    /// - Returns: The least-used palette color, or `nil` for an empty palette.
    static func nextColorHex(
        palette: [WorkspaceTabColorEntry],
        usedHexes: [String],
        reservedHexes: [String] = []
    ) -> String? {
        var allocator = WorkspaceAutoTabColorAllocator(
            palette: palette,
            usedHexes: usedHexes,
            reservedHexes: reservedHexes
        )
        return allocator.next()
    }

    /// Resolves the rail color for one workspace, applying the full enablement rule.
    ///
    /// Returns `nil` — leaving the rail hidden exactly as today — whenever the
    /// indicator style is not `leftRailAuto`, the workspace already carries a
    /// manual color, or no color has been assigned.
    ///
    /// An empty `customColorHex` counts as no manual color, matching the
    /// allocator, which also treats it as uncolored and hands the workspace an
    /// auto color. Disagreeing here would assign a color and then refuse to
    /// draw it.
    static func railColorHex(
        indicatorStyle: WorkspaceIndicatorStyle,
        customColorHex: String?,
        assignedColorHex: String?
    ) -> String? {
        guard indicatorStyle.automaticallyAssignsWorkspaceColors,
              customColorHex?.isEmpty != false else {
            return nil
        }
        return assignedColorHex
    }

    /// Case- and whitespace-insensitive key for comparing palette hexes.
    static func normalized(_ hex: String) -> String {
        hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
