import CoreGraphics

/// How wide each right sidebar mode tab is. The selected tab keeps its full
/// label; the others share what is left equally, none wider than its full
/// label, so a wide sidebar leaves the extra space empty instead of padding
/// the tabs. A tab never goes below its floor (its icon and an ellipsis).
struct RightSidebarModeBarTabWidths {
    let widths: [CGFloat]

    /// - Parameters:
    ///   - natural: Each tab's width with its full label.
    ///   - floors: Each tab's smallest width.
    ///   - selected: The selected tab's index, if any.
    ///   - available: The width for all tabs, with the gaps between them removed.
    init(natural: [CGFloat], floors: [CGFloat], selected: Int?, available: CGFloat) {
        precondition(natural.count == floors.count)
        var result = floors
        var open = Array(natural.indices)
        var availableForOpen = max(0, available)
        if let selected, natural.indices.contains(selected) {
            result[selected] = max(floors[selected], natural[selected])
            availableForOpen = max(0, available - result[selected])
            open.removeAll { $0 == selected }
        }
        // The selected tab stays readable even when the bar cannot fit every
        // tab's floor. Water-fill the unselected tabs by their absolute target
        // width, freezing a tab whose floor or natural width already exceeds
        // the current target before sharing the remainder.
        while !open.isEmpty {
            let share = availableForOpen / CGFloat(open.count)
            let satisfied = open.filter { floors[$0] > share || natural[$0] <= share }
            if satisfied.isEmpty {
                for index in open { result[index] = share }
                break
            }
            for index in satisfied {
                let width = max(floors[index], natural[index] <= share ? natural[index] : floors[index])
                result[index] = width
                availableForOpen -= width
            }
            open.removeAll { satisfied.contains($0) }
        }

        widths = result
    }
}
