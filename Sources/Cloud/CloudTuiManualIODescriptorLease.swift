import Darwin

/// Closes a socket descriptor only after every registered dispatch source cancels.
// @unchecked Sendable is safe because every method is invoked by a cancellation
// handler targeted at the owning connection's serial queue.
final class CloudTuiManualIODescriptorLease: @unchecked Sendable {
    let descriptor: Int32
    private var remainingSources = 0
    private var didClose = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    // The descriptor is closed by `closeIfReady()` only after every registered
    // dispatch source has cancelled. Closing here would race a source that
    // still holds an internal reference to the descriptor.
    deinit {}

    /// Registers one dispatch source before it is activated.
    func registerSource() {
        remainingSources += 1
    }

    /// Called by a source cancellation handler on the connection queue.
    func sourceDidCancel() {
        guard remainingSources > 0 else { return }
        remainingSources -= 1
        closeIfReady()
    }

    /// Closes an unregistered descriptor after all sources have cancelled.
    func closeIfReady() {
        guard remainingSources == 0, !didClose else { return }
        didClose = true
        Darwin.close(descriptor)
    }
}
