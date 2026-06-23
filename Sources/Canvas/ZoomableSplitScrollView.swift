import AppKit

@MainActor
final class ZoomableSplitScrollView: NSScrollView {
    var shouldSuppressPlainDocumentScroll: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        guard shouldSuppressOuterScroll(for: event) else {
            super.scrollWheel(with: event)
            return
        }
    }

    func shouldSuppressOuterScroll(for event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option) else {
            return false
        }
        return shouldSuppressPlainDocumentScroll?(event) == true
    }
}
