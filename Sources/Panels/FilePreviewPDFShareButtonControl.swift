import AppKit

/// Native share control that reports pointer and non-pointer activation explicitly.
@MainActor
final class FilePreviewPDFShareButtonControl: NSButton {
    private(set) var shareActivation: FilePreviewPDFShareActivation = .nonPointer

    override var isEnabled: Bool {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        shareActivation = .pointerDown
        defer { shareActivation = .nonPointer }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        shareActivation = .nonPointer
        return sendAction(action, to: target)
    }
}
