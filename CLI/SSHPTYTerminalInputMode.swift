import Darwin

/// Owns terminal input across one persistent SSH PTY attachment.
///
/// A reattach starts disconnected and does not install an input pump until the
/// daemon's declared replay prefix has been delivered. `TCSAFLUSH` makes the
/// transition authoritative: bytes queued before that boundary are discarded
/// instead of being replayed into a shell whose input state is unknown.
final class SSHPTYTerminalInputMode {
    enum Phase: Equatable {
        case disconnected
        case forwarding
    }

    private let fileDescriptor: Int32
    private var original = termios()
    private var restored = false

    init?(phase: Phase, fileDescriptor: Int32 = STDIN_FILENO) {
        self.fileDescriptor = fileDescriptor
        guard tcgetattr(fileDescriptor, &original) == 0,
              apply(phase, action: TCSAFLUSH) else {
            return nil
        }
    }

    deinit {
        _ = restore()
    }

    /// Discards detached input and switches to the raw forwarding mode.
    @discardableResult
    func beginForwarding() -> Bool {
        guard !restored else { return false }
        return apply(.forwarding, action: TCSAFLUSH)
    }

    /// Restores the caller's terminal mode.
    @discardableResult
    func restore(flushInput: Bool = false) -> Bool {
        guard !restored else { return true }
        var state = original
        let result = tcsetattr(fileDescriptor, flushInput ? TCSAFLUSH : TCSANOW, &state) == 0
        if result {
            restored = true
        }
        return result
    }

    /// Drops unread bytes from a terminal input queue.
    @discardableResult
    static func flushInput(fileDescriptor: Int32 = STDIN_FILENO) -> Bool {
        tcflush(fileDescriptor, TCIFLUSH) == 0
    }

    private func apply(_ phase: Phase, action: Int32) -> Bool {
        var state = original
        cfmakeraw(&state)
        if phase == .disconnected {
            // Ctrl-C and the other configured signal keys must continue to
            // stop a reconnect while ordinary bytes remain hidden and disposable.
            state.c_lflag |= tcflag_t(ISIG)
        }
        return tcsetattr(fileDescriptor, action, &state) == 0
    }
}
