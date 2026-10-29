import AppKit
@testable import CmuxNextDesign
import Testing

/// Escape that reaches the overlay layer outside a window's top layer (in the overlay panel, or with no
/// cancel handler) goes on up the responder chain. It never calls `super`: NSView does not implement
/// `cancelOperation:`, so the super call raised "unrecognized selector" and ended the app.
@MainActor @Suite struct OverlayTopLayerCancelTests {
    /// Records the Escape the chain passes on, as the overlay panel's own `cancelOperation` takes it.
    final class CancelRecorder: NSResponder {
        var cancels = 0

        override func cancelOperation(_ sender: Any?) { cancels += 1 }
    }

    @Test func escapeOutsideTheWindowTopLayerGoesToTheNextResponder() {
        _ = NSApplication.shared
        let layer = OverlayTopLayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let recorder = CancelRecorder()
        layer.nextResponder = recorder
        #expect(!layer.isWindowTopLayer)
        layer.cancelOperation(nil)
        #expect(recorder.cancels == 1)
    }

    @Test func escapeThatNoResponderTakesEndsQuietly() {
        _ = NSApplication.shared
        let layer = OverlayTopLayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        layer.nextResponder = NSResponder()
        layer.cancelOperation(nil)
        #expect(layer.nextResponder != nil)
    }
}
