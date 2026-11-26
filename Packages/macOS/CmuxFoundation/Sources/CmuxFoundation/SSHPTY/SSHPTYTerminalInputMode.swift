import Darwin

/// Owns terminal input across one persistent SSH PTY attachment.
///
/// A reattach starts disconnected and does not install an input pump until the
/// daemon's declared replay prefix has been delivered. The input queue is
/// flushed before forwarding starts, without waiting for a stalled terminal
/// output reader to drain.
public final class SSHPTYTerminalInputMode {
    private enum Phase: Equatable {
        case unchanged
        case disconnected
        case forwarding
        case restored
    }

    private let fileDescriptor: Int32
    private var original = termios()
    private var phase: Phase = .unchanged

    /// Captures the caller's complete mode without changing or flushing the PTY.
    /// - Parameter fileDescriptor: Borrowed terminal descriptor owned by the caller.
    public init?(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        guard tcgetattr(fileDescriptor, &original) == 0 else {
            return nil
        }
    }

    /// Protects detached input only after the daemon has passed admission.
    public func beginDisconnected() -> Bool {
        guard phase == .unchanged else { return phase == .disconnected }
        return apply(.disconnected, flushInput: true)
    }

    deinit {
        _ = restore()
    }

    /// Discards detached input and switches to the raw forwarding mode.
    @discardableResult
    public func beginForwarding() -> Bool {
        switch phase {
        case .forwarding: return true
        case .restored: return false
        case .unchanged: return apply(.forwarding, flushInput: false)
        case .disconnected: return apply(.forwarding, flushInput: true)
        }
    }

    /// Restores the caller's terminal mode.
    /// - Parameter flushInput: Whether to discard queued detached input.
    /// - Returns: Whether restoration succeeded or no mutation needs undoing.
    @discardableResult
    public func restore(flushInput: Bool = false) -> Bool {
        if phase == .unchanged {
            if flushInput, !Self.flushInput(fileDescriptor: fileDescriptor) { return false }
            phase = .restored
        }
        guard phase != .restored else { return true }
        var state = original
        guard tcsetattr(fileDescriptor, TCSANOW, &state) == 0 else { return false }
        phase = .restored
        return !flushInput || Self.flushInput(fileDescriptor: fileDescriptor)
    }

    /// Drops unread bytes from a terminal input queue.
    /// - Parameter fileDescriptor: Borrowed terminal descriptor owned by the caller.
    /// - Returns: Whether the input queue was flushed.
    @discardableResult
    public static func flushInput(fileDescriptor: Int32) -> Bool {
        tcflush(fileDescriptor, TCIFLUSH) == 0
    }

    private func apply(_ phase: Phase, flushInput: Bool) -> Bool {
        var state = original
        cfmakeraw(&state)
        if phase == .disconnected {
            // Ctrl-C and the other configured signal keys must continue to
            // stop a reconnect while ordinary bytes remain hidden and disposable.
            state.c_lflag |= tcflag_t(ISIG)
        }
        // TCSAFLUSH also drains output, which can block termination indefinitely.
        // Input has no consumer until this method returns, so flush it separately.
        guard tcsetattr(fileDescriptor, TCSANOW, &state) == 0 else { return false }
        self.phase = phase
        return !flushInput || Self.flushInput(fileDescriptor: fileDescriptor)
    }
}
