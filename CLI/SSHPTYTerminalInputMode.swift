import Darwin
import Foundation

/// Owns the terminal mode while a persistent SSH PTY is detached.
///
/// A reconnect attempt can spend seconds waiting for the local remote-session
/// controller before it has a bridge file descriptor. Keeping the terminal in
/// a non-echoing mode for that whole interval prevents keystrokes from being
/// rendered locally; `TCSAFLUSH` at the forwarding boundary then discards the
/// detached queue before the live PTY receives input.
final class SSHPTYTerminalInputMode {
    /// The two terminal phases used by a persistent attach.
    enum Phase: Equatable {
        /// Input is intentionally discarded until a bridge is ready.
        case disconnected
        /// Input is forwarded by the bridge pump.
        case forwarding
    }

    private var original = termios()
    private var restored = false

    /// Captures the current terminal and applies the requested phase.
    init?(phase: Phase) {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return nil
        }
        guard apply(phase, action: TCSAFLUSH) else {
            return nil
        }
    }

    deinit {
        _ = restore()
    }

    /// Switches from detached input handling to live PTY forwarding.
    @discardableResult
    func beginForwarding() -> Bool {
        guard !restored else { return true }
        return apply(.forwarding, action: TCSAFLUSH)
    }

    /// Restores the caller's terminal mode and optionally flushes queued input.
    @discardableResult
    func restore(flushInput: Bool = false) -> Bool {
        guard !restored else { return true }
        var state = original
        guard tcsetattr(STDIN_FILENO, flushInput ? TCSAFLUSH : TCSANOW, &state) == 0 else {
            return false
        }
        restored = true
        return true
    }

    /// Drops unread bytes from one terminal input queue.
    @discardableResult
    static func flushInput(fd: Int32 = STDIN_FILENO) -> Bool {
        tcflush(fd, TCIFLUSH) == 0
    }

    private func apply(_ phase: Phase, action: Int32) -> Bool {
        var state = original
        cfmakeraw(&state)
        if phase == .disconnected {
            // Keep interrupt keys signal-generating while the wrapper owns the
            // detached phase; ordinary bytes remain hidden and disposable.
            state.c_lflag |= tcflag_t(ISIG)
        }
        return tcsetattr(STDIN_FILENO, action, &state) == 0
    }
}
