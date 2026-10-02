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
        if let selected, natural.indices.contains(selected) {
            result[selected] = max(floors[selected], natural[selected])
            open.removeAll { $0 == selected }
        }
        // The selected tab stays readable even when the bar cannot fit every
        // tab's floor. Unselected tabs then share only the space left after
        // their floors have been reserved.
        var remaining = max(0, available - result.reduce(0, +))
        while !open.isEmpty, remaining > 0 {
            let share = remaining / CGFloat(open.count)
            let satisfied = open.filter { natural[$0] - result[$0] <= share }
            if satisfied.isEmpty {
                for index in open { result[index] += share }
                break
            }
            for index in satisfied {
                let extra = max(0, natural[index] - result[index])
                result[index] += extra
                remaining -= extra
            }
            open.removeAll { satisfied.contains($0) }
        }
        widths = result
    }
}
