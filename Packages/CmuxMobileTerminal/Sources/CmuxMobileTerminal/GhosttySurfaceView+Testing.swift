#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

// MARK: - Testing Hooks & Text Inspection
extension GhosttySurfaceView {
    func simulateTextInputForTesting(_ text: String) {
        setFocus(true)
        sendText(text)
        runtime?.tick()
    }

    func simulatePasteInputForTesting(_ text: String) {
        setFocus(true)
        sendPaste(text)
        runtime?.tick()
    }

    func simulateInputProxyTextChangeForTesting(_ text: String, isComposing: Bool) {
        setFocus(true)
        inputProxy.simulateTextChangeForTesting(text, isComposing: isComposing)
        runtime?.tick()
    }

    func renderedTextForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        guard let surface else { return nil }

        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }

        let data = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: data, as: UTF8.self)
    }

    #if DEBUG
    func accessibilityRenderedTextForTesting() -> String? {
        let candidates = [
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SURFACE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SCREEN),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_ACTIVE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT),
        ].compactMap { $0 }

        return candidates.max { lhs, rhs in
            lhs.utf8.count < rhs.utf8.count
        }
    }

    /// Throttle stamp for the off-main accessibility-label read in
    /// `processOutput`. Accessed only on the serial `outputQueue`, so the
    /// unchecked mutation is safe.
    nonisolated(unsafe) internal static var lastAccessibilityTextTime: CFTimeInterval = 0

    /// Off-main equivalent of ``accessibilityRenderedTextForTesting()`` that
    /// reads via the raw surface handle so it can run on the serial output queue
    /// (alongside `process_output`) instead of the main thread. See the call
    /// site in `processOutput` for why a main-thread read deadlocks the watchdog.
    nonisolated static func accessibilitySurfaceText(_ surface: ghostty_surface_t) -> String? {
        let candidates = [
            surfaceText(surface, pointTag: GHOSTTY_POINT_SURFACE),
            surfaceText(surface, pointTag: GHOSTTY_POINT_SCREEN),
            surfaceText(surface, pointTag: GHOSTTY_POINT_ACTIVE),
            surfaceText(surface, pointTag: GHOSTTY_POINT_VIEWPORT),
        ].compactMap { $0 }
        return candidates.max { $0.utf8.count < $1.utf8.count }
    }

    #endif

    /// Read the surface text for `pointTag` from the raw handle. Pure libghostty
    /// C calls, safe to run off the main actor on the serial output queue.
    ///
    /// Intentionally not `#if DEBUG`-gated: the non-DEBUG, release-shipping
    /// ``visibleTerminalSnapshot()`` (Copy Debug Logs) calls this, so gating it
    /// out breaks the Release/TestFlight archive while compiling fine in Debug.
    nonisolated static func surfaceText(_ surface: ghostty_surface_t, pointTag: ghostty_point_tag_e) -> String? {
        let topLeft = ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    func renderedHTMLForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        _ = pointTag
        // ghostty_surface_read_text_html not available in this build
        return nil
    }

    func processExitedForTesting() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_process_exited(surface)
    }

    func visibleSnapshotTextForTesting() -> String {
        snapshotFallbackView.attributedText?.string ?? snapshotFallbackView.text
    }

    func visibleSnapshotAttributedTextForTesting() -> NSAttributedString? {
        snapshotFallbackView.attributedText
    }

    func isUsingSnapshotFallbackForTesting() -> Bool {
        !snapshotFallbackView.isHidden
    }

}

#endif
