import AppKit

extension GhosttyNSView {
    /// Whether another process posted `event` rather than the keyboard or cmux.
    ///
    /// Hardware events carry source PID 0, and events cmux synthesizes carry
    /// its own PID. Anything else was injected by another app, for example a
    /// dictation tool's global hotkey.
    static func isKeyEventPostedByAnotherProcess(
        _ event: NSEvent,
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        guard let sourceProcessID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID),
              sourceProcessID != 0 else { return false }
        return sourceProcessID != Int64(currentProcessID)
    }

    /// Whether to swallow a Command+Option chord that missed both the menu
    /// and every Ghostty binding, instead of typing it into the terminal.
    ///
    /// Dictation tools can post their own hotkey (Cmd+Option+C while Option
    /// is held as push-to-talk) into the focused app. Nothing in cmux handles
    /// that chord, so it would reach the program as a stray character. Only
    /// chords injected by another process are dropped; the same chord from
    /// the keyboard still reaches the terminal. Command chords without Option
    /// are left alone so remote-control and automation tools keep working.
    func shouldDropForeignUnboundCommandChord(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.option),
              Self.isKeyEventPostedByAnotherProcess(event) else { return false }
#if DEBUG
        cmuxDebugLog(
            "key.foreignCommandChord.drop keyCode=\(event.keyCode) " +
            "mods=\(flags.rawValue)"
        )
#endif
        return true
    }
}
