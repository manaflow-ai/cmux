#if canImport(UIKit)
import GhosttyKit
import UIKit

/// Test-only observation hooks (reached via `@testable import`); kept out of
/// GhosttySurfaceView.swift so test plumbing does not grow the main file.
extension GhosttySurfaceView {
    func renderedHTMLForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        _ = pointTag
        // ghostty_surface_read_text_html not available in this build
        return nil
    }

    func processExitedForTesting() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_process_exited(surface)
    }
}
#endif
