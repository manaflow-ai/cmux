#if canImport(UIKit)
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    /// "What the user sees": the visible viewport text of every on-screen
    /// terminal surface, for the DEV "Copy Debug Logs" action so a bug report
    /// pairs the on-screen content with the debug log. Reads the VIEWPORT
    /// (visible grid only, not scrollback) via libghostty.
    public static func visibleTerminalSnapshot() -> String {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        var pending: [
            (
                grid: String,
                font: Int,
                surface: ghostty_surface_t,
                executor: GhosttySurfaceWorkExecutor
            )
        ] = []
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            guard view.window != nil, !view.isHidden, view.alpha > 0.01,
                  let surface = view.surface else { continue }
            let grid = view.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "?"
            pending.append((
                grid: grid,
                font: Int(view.liveFontSize),
                surface: surface,
                executor: view.surfaceExecutor
            ))
        }
        if pending.isEmpty {
            return "===== visible terminal: (no on-screen surface) ====="
        }

        let group = DispatchGroup()
        let boxes = pending.map { _ in VisibleTerminalSnapshotResultBox() }
        for (index, item) in pending.enumerated() {
            group.enter()
            item.executor.async(surface: item.surface) { handle in
                let text = surfaceText(handle.surface, pointTag: GHOSTTY_POINT_VIEWPORT) ?? "(unavailable)"
                let section = "===== visible terminal · grid=\(item.grid) · font=\(item.font) =====\n"
                    + text
                boxes[index].section = section
                group.leave()
            }
        }
        if group.wait(timeout: .now() + 0.6) == .timedOut {
            return "===== visible terminal: (snapshot skipped — render busy) ====="
        }
        return boxes.compactMap(\.section).joined(separator: "\n\n")
    }
}
#endif
