// DEBUG and Demo builds only: the flood benchmark's drivers are never compiled into Production.
#if os(iOS) && DEBUG
import QuartzCore

/// DEBUG only. Drivers for the flood benchmark's agent workload (`TerminalFloodBench` in
/// CmuxMobileLive, `TerminalTypingWhileStreamingUITests`): they act on the terminal the way a
/// person does, through the same calls UIKit makes.
extension TerminalModel {
    /// One key typed into the terminal the way the software keyboard types it (`insertText` on
    /// the surface, then the caret query UIKit makes after every text change). Returns the main
    /// thread's milliseconds for the key; nil before the surface exists.
    public func benchTypeNativeKey(_ text: String) -> Double? {
        guard let surface = controller?.surface, surface.surface != nil else { return nil }
        let start = CACurrentMediaTime()
        surface.insertText(text)
        _ = surface.caretRect(for: surface.endOfDocument)
        return (CACurrentMediaTime() - start) * 1000
    }

    /// The terminal takes the keyboard, as a tap on it does, so UIKit's text system (its input
    /// delegate, the keyboard) is in the loop for each key.
    public func benchFocusTerminal() {
        controller?.focusTerminal()
    }
}
#endif
