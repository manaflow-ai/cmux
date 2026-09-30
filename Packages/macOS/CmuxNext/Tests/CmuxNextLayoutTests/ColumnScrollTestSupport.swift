import CoreGraphics
import CmuxNextDesign
@testable import CmuxNextLayout

/// Builds a strip by hand: columns `c<i>` (or `ids`) with one pane `p<i>`
/// each, laid left to right with `gap` before, between and after them.
func makeStrip(_ widths: [CGFloat], ids: [String]? = nil, viewport: CGFloat = 1000, gap: CGFloat = 8) -> ColumnStrip {
    var x = gap
    var columns: [ColumnStrip.Column] = []
    for (index, width) in widths.enumerated() {
        let name = ids?[index] ?? "\(index)"
        let frame = CGRect(x: x, y: 0, width: width, height: 600)
        let pane = PaneID("p\(name)")
        columns.append(ColumnStrip.Column(id: ColumnID("c\(name)"), frame: frame, panes: [pane], paneFrames: [pane: frame]))
        x += width + gap
    }
    return ColumnStrip(columns: columns, viewportWidth: viewport, contentWidth: columns.isEmpty ? viewport : x, gap: gap)
}

/// A state placed on `strip` with `focused` at rest.
func settledState(_ strip: ColumnStrip, focused: String, mode: CenterFocusedColumn = .never) -> ColumnScrollState {
    var state = ColumnScrollState()
    state.mode = mode
    state.reduce(.sync(strip, focused: PaneID(focused), source: .programmatic, animated: false))
    return state
}

extension ColumnScrollState {
    /// Steps the spring at 120 Hz until it rests; returns every presented value.
    @discardableResult
    mutating func runToRest(maxFrames: Int = 600) -> [CGFloat] {
        var values: [CGFloat] = []
        for _ in 0..<maxFrames {
            let moving = spring.advance(1.0 / 120.0, parameters: Motion.spring(.scroll), epsilon: 0.25)
            values.append(spring.value)
            if !moving { break }
        }
        return values
    }

    mutating func focus(_ pane: String, source: ColumnFocusSource = .keyboard, animated: Bool = true) {
        guard let strip else { return }
        reduce(.sync(strip, focused: PaneID(pane), source: source, animated: animated))
    }

    /// Screen x of a column's leading edge at the presented offset.
    func screenX(of column: String) -> CGFloat? {
        strip?.columns.first { $0.id == ColumnID(column) }.map { $0.frame.minX - spring.value }
    }
}
