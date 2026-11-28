#if canImport(CCmuxNativeTranscriptFFI)
import AppKit
import CmuxNextDesign
import Foundation

/// The window that holds the native transcript (RFD 0121, app-perf.md section 6, first PR): read-only, the 3,000-row
/// bench fixture, never on by default. It opens only when asked: `CMUX_NATIVE_TRANSCRIPT=1` at launch
/// (``openIfAsked()``), or `debug.native_transcript` `open` in a Debug or bench build. The React transcript stays
/// every chat's transcript; this window is a measurement surface beside it.
/// ``NativeTranscriptControl`` owns the one open window (the App constructs that control once, in AppServices).
final class NativeTranscriptWindow: NSObject, NSWindowDelegate {
    static let environmentKey = "CMUX_NATIVE_TRANSCRIPT"
    let window: NSWindow
    let view: NativeTranscriptView
    /// Called once the window closed (its own close button or ``close()``), so its owner drops it.
    var onClose: () -> Void = {}

    /// Whether this launch asked for the native transcript (`CMUX_NATIVE_TRANSCRIPT=1`).
    static var askedByEnvironment: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    /// Shows the window with a `size`-point transcript; `then` gets its renderer once the render thread made it
    /// (nil: no GPU, or the scene refused the size).
    func show(size: CGSize, then: @escaping (NativeTranscriptRenderer?) -> Void) {
        if window.contentLayoutRect.size != size, size.width > 0, size.height > 0 { window.setContentSize(size) }
        WindowActivation.show(window, .focus)
        view.start(then: then)
    }

    /// Closes the window; the render thread stops and frees the scene.
    func close() {
        view.stop()
        window.close()
    }

    init(size: CGSize) {
        let frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        view = NativeTranscriptView(frame: frame)
        super.init()
        window.title = "Native transcript (RFD 0121, read-only)"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        view.stop()
        onClose()
    }
}
#endif
