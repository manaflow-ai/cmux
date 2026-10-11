#if DEBUG
import AppKit

extension WindowScopedShortcutHintModifierMonitor {
    /// Posts a synthetic flags event through the same monitor entrypoint as AppKit.
    func debugEvent(_ flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                        keyCode: flags.contains(.control) ? 59 : 55)
    }
}
#endif
