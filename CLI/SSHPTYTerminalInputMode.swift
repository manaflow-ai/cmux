import Darwin

/// Owns terminal input across one persistent SSH PTY attachment.
///
/// A reattach starts disconnected and does not install an input pump until the
/// daemon's declared replay prefix has been delivered. `TCSAFLUSH` makes the
/// transition authoritative: bytes queued before that boundary are discarded
/// instead of being replayed into a shell whose input state is unknown.
final class SSHPTYTerminalInputMode {
    enum Phase: Equatable {
        case unchanged
        case disconnected
        case forwarding
        case restored
    }

    private let fileDescriptor: Int32
    private var original = termios()
    private var phase: Phase = .unchanged

    /// Captures the caller's complete mode without changing or flushing the PTY.
    init?(fileDescriptor: Int32 = STDIN_FILENO) {
        self.fileDescriptor = fileDescriptor
        guard tcgetattr(fileDescriptor, &original) == 0 else {
            return nil
        }
    }

    /// Protects detached input only after the daemon has passed admission.
    func beginDisconnected() -> Bool {
        guard phase == .unchanged else { return phase == .disconnected }
        return apply(.disconnected, action: TCSAFLUSH)
    }

    deinit {
        _ = restore()
    }

    /// Discards detached input and switches to the raw forwarding mode.
    @discardableResult
    func beginForwarding() -> Bool {
        switch phase {
        case .forwarding: return true
        case .restored: return false
        case .unchanged: return apply(.forwarding, action: TCSANOW)
        case .disconnected: return apply(.forwarding, action: TCSAFLUSH)
        }
    }

    /// Restores the caller's terminal mode.
    @discardableResult
    func restore(flushInput: Bool = false) -> Bool {
        if phase == .unchanged { phase = .restored }
        guard phase != .restored else { return true }
        var state = original
        let result = tcsetattr(fileDescriptor, flushInput ? TCSAFLUSH : TCSANOW, &state) == 0
        if result {
            phase = .restored
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
        guard tcsetattr(fileDescriptor, action, &state) == 0 else { return false }
        self.phase = phase
        return true
    }
}
