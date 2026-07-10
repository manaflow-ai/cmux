import AppKit

@MainActor
final class SurfacePipPanel: NSPanel {
    var onCancelOperation: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        _ = sender
        onCancelOperation?()
    }
}
