public import AppKit

/// `debug.layers` with `titlebar_band`: what a press does across a window's
/// top row, in `debug.mouse` coordinates (window-local points from the
/// top-left). Per sampled row `y`, runs of x with one answer: whether
/// `TitlebarDragPolicy` moves the window there, the view a click lands on,
/// and the `TitlebarPressDeciding` view that answered, if any. A drag area
/// should be drawn where it moves the window and nowhere else (Leo,
/// cosmic-gray 2026-10-13). A `JSONSerialization` object graph.
extension NSWindow {
    public func titlebarBandMap(step: CGFloat = 2) -> [String: Any] {
        guard let content = contentView, let frameView = content.superview else { return ["error": "no window"] }
        let height = content.bounds.height, width = content.bounds.width
        let band = TitlebarDragPolicy.bandRect(in: self)
        let step = max(1, step)
        // The band and a strip's height below it: a top-row strip can be taller than the band.
        let bottom = min(band.minY, band.maxY - Metrics.tabStripHeight)
        var rows: [[String: Any]] = []
        for y in stride(from: band.maxY - 2, through: bottom + 1, by: -4) {
            var runs: [[String: Any]] = []
            var current: (start: CGFloat, key: [String])?
            func close(at x: CGFloat) {
                guard let run = current else { return }
                runs.append(["x": [Double(run.start), Double(x)], "moves": run.key[0] == "moves", "hit": run.key[1], "decider": run.key[2]])
            }
            for x in stride(from: CGFloat(0), through: width, by: step) {
                let point = CGPoint(x: x, y: y)
                let hit = frameView.hitTest(frameView.convert(point, from: nil))
                let decider = sequence(first: hit, next: { $0?.superview }).lazy.compactMap { $0 as? TitlebarPressDeciding }.first
                let key = [TitlebarDragPolicy.decide(at: point, in: self) == .movesWindow ? "moves" : "stays",
                           hit.map { String(describing: type(of: $0)) } ?? "nil",
                           decider.map { String(describing: type(of: $0)) } ?? ""]
                if current?.key != key {
                    close(at: x)
                    current = (x, key)
                }
            }
            close(at: width)
            rows.append(["y": Double(height - y), "runs": runs])
        }
        return ["band": [band.minX, height - band.maxY, band.width, band.height].map(Double.init), "rows": rows]
    }
}
