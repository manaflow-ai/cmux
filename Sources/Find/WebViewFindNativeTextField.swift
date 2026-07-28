import AppKit

/// Borderless native field used by find bars layered over WebKit panels.
@MainActor
final class WebViewFindNativeTextField: FindSelectionTrackingTextField {
    var onMovedToWindow: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onMovedToWindow?()
    }
}
