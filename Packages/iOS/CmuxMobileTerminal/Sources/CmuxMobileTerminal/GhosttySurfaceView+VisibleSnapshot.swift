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
        let sections = UnsafeMutableBufferPointer<String?>.allocate(capacity: pending.count)
        sections.initialize(repeating: nil)
        let releaseSections = {
            sections.deinitialize()
            sections.deallocate()
        }
        for (index, item) in pending.enumerated() {
            group.enter()
            item.executor.async {
                let text = surfaceText(item.surface, pointTag: GHOSTTY_POINT_VIEWPORT) ?? "(unavailable)"
                let section = "===== visible terminal · grid=\(item.grid) · font=\(item.font) =====\n"
                    + text
                sections[index] = section
                group.leave()
            }
        }
        if group.wait(timeout: .now() + 0.6) == .timedOut {
            group.notify(queue: .global(qos: .utility)) {
                releaseSections()
            }
            return "===== visible terminal: (snapshot skipped — render busy) ====="
        }
        let snapshot = sections.compactMap { $0 }.joined(separator: "\n\n")
        releaseSections()
        return snapshot
    }
}
#endif
