import AppKit
import WebKit

@MainActor
final class AgentSessionWebView: WKWebView {
    var onPointerDown: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard (event.keyCode == 36 || event.keyCode == 76),
              flags.isEmpty || flags == [.shift],
              !shortcutResponderHasMarkedText(self) else {
            return super.performKeyEquivalent(with: event)
        }

        // AppKit asks the first responder to resolve Return as a key equivalent
        // before WebKit delivers it to the contenteditable composer. Forward the
        // key-down through WebKit's native delivery owner so ProseMirror receives
        // the trusted DOM key event without re-entering cmux's window router.
        browserNativeInputDeliveryOwner.withDispatch {
            super.keyDown(with: event)
        }
        return true
    }
}
