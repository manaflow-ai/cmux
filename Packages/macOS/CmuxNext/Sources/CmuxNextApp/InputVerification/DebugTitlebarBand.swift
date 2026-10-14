#if DEBUG
import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// `debug.titlebar_band` (DEBUG builds): what a press does across a window's
/// top row, in `debug.mouse` coordinates (window-local points from the
/// top-left). Per sampled row `y`, runs of x with one answer: whether
/// `TitlebarDragPolicy` moves the window there, the view a click lands on,
/// and the `TitlebarPressDeciding` view that answered, if any. A drag area
/// should be drawn where it moves the window and nowhere else (Leo,
/// cosmic-gray 2026-10-13). Params: `window` (id), `step` (x step, default 2).
enum DebugTitlebarBand {
    static func report(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let window = controller.window, let content = window.contentView, let frameView = content.superview else {
            return .object(["error": .string("no window")])
        }
        let height = content.bounds.height, width = content.bounds.width
        let band = TitlebarDragPolicy.bandRect(in: window)
        let step = CGFloat(max(1, params["step"]?.doubleValue ?? 2))
        // The band and a strip's height below it: a top-row strip can be taller than the band.
        let bottom = min(band.minY, band.maxY - Metrics.tabStripHeight)
        var rows: [JSONValue] = []
        for y in stride(from: band.maxY - 2, through: bottom + 1, by: -4) {
            var runs: [JSONValue] = []
            var current: (start: CGFloat, key: [String])?
            func close(at x: CGFloat) {
                guard let run = current else { return }
                runs.append(.object(["x": .array([.number(Double(run.start)), .number(Double(x))]), "moves": .bool(run.key[0] == "moves"),
                                     "hit": .string(run.key[1]), "decider": .string(run.key[2])]))
            }
            for x in stride(from: CGFloat(0), through: width, by: step) {
                let point = CGPoint(x: x, y: y)
                let hit = frameView.hitTest(frameView.convert(point, from: nil))
                let decider = sequence(first: hit, next: { $0?.superview }).lazy.compactMap { $0 as? TitlebarPressDeciding }.first
                let key = [TitlebarDragPolicy.decide(at: point, in: window) == .movesWindow ? "moves" : "stays",
                           hit.map { String(describing: type(of: $0)) } ?? "nil",
                           decider.map { String(describing: type(of: $0)) } ?? ""]
                if current?.key != key {
                    close(at: x)
                    current = (x, key)
                }
            }
            close(at: width)
            rows.append(.object(["y": .number(Double(height - y)), "runs": .array(runs)]))
        }
        return .object([
            "window": .string(controller.state.id),
            "band": .array([band.minX, height - band.maxY, band.width, band.height].map { .number(Double($0)) }),
            "rows": .array(rows),
        ])
    }
}
#endif
