#if DEBUG
import AppKit
import os
import QuartzCore

/// Dogfood probe for #22287 (drop target flicker): logs each change of what the tab drop overlay
/// shows, with the pointer, under `log stream --predicate 'subsystem == "com.cmuxterm.app.next" &&
/// category == "tabdrop"'`. Removed before merge.
extension LayoutRootView {
    private static let tabDropLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tabdrop")

    func probeTabDrop(_ shown: String, at point: CGPoint? = nil) {
        guard shown != tabDropProbeLast else { return }
        tabDropProbeLast = shown
        let at = point.map { " at \(Int($0.x)),\(Int($0.y))" } ?? ""
        Self.tabDropLog.debug("tabdrop \(shown, privacy: .public)\(at, privacy: .public) t=\(CACurrentMediaTime(), privacy: .public)")
    }
}
#endif
