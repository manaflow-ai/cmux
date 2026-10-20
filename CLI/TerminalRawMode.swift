import Darwin

/// Temporarily applies the conventional raw mode to standard input.
final class TerminalRawMode {
    private var original = termios()
    private var restored = false

    init?() {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return nil
        }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            return nil
        }
    }

    deinit {
        restore()
    }

    func restore(flushInput: Bool = false) {
        guard !restored else { return }
        _ = tcsetattr(STDIN_FILENO, flushInput ? TCSAFLUSH : TCSANOW, &original)
        restored = true
    }
}
