import AppKit

@MainActor
final class RecordingMouseDownView: NSView {
    private(set) var mouseDownCount = 0

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
    }
}
