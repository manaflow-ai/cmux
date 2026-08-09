import CmuxSettings
import Foundation

/// Hands out palette colors for a run of workspaces, carrying its bookkeeping
/// from one pick to the next.
///
/// The rule is the one described on `WorkspaceAutoTabColorAssignment`: the
/// least-used color wins, ties go to whichever color looks furthest from the
/// colors already on screen, and a color reserved for a manually overridden
/// workspace is only spent when nothing else is equally cheap.
///
/// Reconciling assigns every uncolored workspace in one pass, so the state
/// lives here rather than being rebuilt per workspace. Recomputing use counts
/// and re-converting every used color to Lab on each pick made a first run over
/// a large workspace list quadratic; keeping the counts, the reserved keys, and
/// each entry's distance to its nearest on-screen color across picks makes each
/// `next()` cost the palette rather than the whole history.
///
/// Deliberately free of AppKit/SwiftUI so the allocation rules stay
/// unit-testable.
struct WorkspaceAutoTabColorAllocator {
    private let palette: [WorkspaceTabColorEntry]
    /// Normalized palette keys and Lab colors, parallel to `palette`, converted
    /// once so a pick never re-parses the palette.
    private let paletteKeys: [String]
    private let paletteLabs: [LabColor?]
    private let paletteKeySet: Set<String>
    private let reservedKeys: Set<String>

    private var counts: [String: Int]
    /// For each palette entry, the distance to the nearest color currently on
    /// screen, parallel to `palette`.
    ///
    /// Folded forward instead of rescanned: distance folds with `min`, and the
    /// set of on-screen colors only grows during a pass, so one comparison
    /// against each newly recorded color keeps every entry exact. Rescanning
    /// per pick cost the whole in-use set on every tied entry, which is where
    /// the quadratic term came back once manual colors made that set large.
    ///
    /// `greatestFiniteMagnitude` means nothing is on screen yet, so every
    /// entry ties and palette order decides.
    private var nearest: [Double]
    /// Distinct colors already folded into `nearest`. A color that appears
    /// twice says nothing new.
    private var seenInUse: Set<String>

    init(
        palette: [WorkspaceTabColorEntry],
        usedHexes: [String],
        reservedHexes: [String] = []
    ) {
        self.palette = palette
        paletteKeys = palette.map { WorkspaceAutoTabColorAssignment.normalized($0.hex) }
        paletteLabs = palette.map { LabColor(hex: $0.hex) }
        paletteKeySet = Set(paletteKeys)
        reservedKeys = Set(reservedHexes.map { WorkspaceAutoTabColorAssignment.normalized($0) })

        counts = [:]
        nearest = Array(repeating: .greatestFiniteMagnitude, count: palette.count)
        seenInUse = []
        for hex in usedHexes {
            record(hex)
        }
    }

    /// Picks the next color and records it as used, or returns `nil` for an
    /// empty palette.
    mutating func next() -> String? {
        guard !palette.isEmpty else { return nil }

        var minimumCount = Int.max
        for key in paletteKeys {
            minimumCount = min(minimumCount, counts[key] ?? 0)
        }

        // Among the least-used colors, take the one furthest from the colors
        // already on screen. Straight palette order would hand out Red then
        // Crimson to the first two workspaces (ΔE 7.7, indistinguishable on a
        // 3pt rail); picking the furthest color gives ΔE 138.7 instead.
        //
        // Manual colors repel too, even when they are not palette entries, so
        // an auto color does not land next to a color the user chose.
        //
        // Two passes over the tied colors, not one: a reserved color is only
        // acceptable when no unreserved color ties, so preferring unreserved
        // cannot be folded into the distance comparison.
        let picked = bestTied(minimumCount: minimumCount, allowingReserved: false)
            ?? bestTied(minimumCount: minimumCount, allowingReserved: true)
        guard let picked else { return nil }

        let hex = palette[picked].hex
        record(hex)
        return hex
    }

    /// Index of the furthest-looking color among those used `minimumCount`
    /// times, or `nil` when none qualifies.
    private func bestTied(minimumCount: Int, allowingReserved: Bool) -> Int? {
        var best: Int?
        var bestDistance = -1.0
        for index in palette.indices {
            guard (counts[paletteKeys[index]] ?? 0) == minimumCount else { continue }
            if !allowingReserved, reservedKeys.contains(paletteKeys[index]) { continue }
            // A color that cannot be converted also cannot be drawn, so it is
            // never worth handing out while a drawable color ties with it.
            guard paletteLabs[index] != nil else { continue }

            // Strict `>` keeps palette order as the tie-break. Before anything
            // is on screen every entry sits at `greatestFiniteMagnitude`, so
            // this picks the first drawable candidate and stays deterministic.
            if nearest[index] > bestDistance {
                best = index
                bestDistance = nearest[index]
            }
        }
        return best
    }

    private mutating func record(_ hex: String) {
        let key = WorkspaceAutoTabColorAssignment.normalized(hex)
        // A manual color outside the palette cannot use up a palette slot, but
        // it still repels, so it is skipped for counting and kept for distance.
        if paletteKeySet.contains(key) {
            counts[key, default: 0] += 1
        }
        guard seenInUse.insert(key).inserted, let lab = LabColor(hex: hex) else { return }
        for index in palette.indices {
            guard let entryLab = paletteLabs[index] else { continue }
            nearest[index] = min(nearest[index], entryLab.distance(to: lab))
        }
    }
}
