#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

/// Debug and bench builds: each `Page.captureScreenshot` cmux sends Chromium is a fact on the step log (`page_capture`,
/// ``ResizeStepTimes/note(_:ms:step:detail:)``, written only while the log streams). Chromium encodes the picture on
/// its UI thread, the app's main thread (`PageHandler::ScreenshotCaptured`), and answers right after, so the two lines
/// of a picture bound when that encode ran: `what=request` at the send, `what=reply` when its answer is back. `fmt=`
/// names the image format, `fast=1` an `optimizeForSpeed` one (the PNG of a parked New Tab spare's frame or a hover
/// card), `open=1` a line inside a resize step, `held=1` a line while a mouse button is down (a drag under way).
enum CEFPageCaptureProbe {
    static let method = "Page.captureScreenshot"

    @MainActor static func sent(_ method: String, params: String) {
        guard method == Self.method else { return }
        let format = params.contains("\"jpeg\"") ? "jpeg" : params.contains("\"webp\"") ? "webp" : "png"
        let fast = params.contains("\"optimizeForSpeed\":true")
        ResizeStepTimes.note("page_capture", ms: 0, detail: " what=request fmt=\(format) fast=\(fast ? 1 : 0)\(state)")
    }

    @MainActor static func answered(_ method: String) {
        guard method == Self.method else { return }
        ResizeStepTimes.note("page_capture", ms: 0, detail: " what=reply\(state)")
    }

    @MainActor private static var state: String {
        " open=\(ResizeStepTimes.openStep != nil ? 1 : 0) held=\(NSEvent.pressedMouseButtons != 0 ? 1 : 0)"
    }
}
#endif
