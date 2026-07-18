/// Registers cleanup work for the currently executing signal effect.
@MainActor
public struct SignalEffectContext {
    private let registerCleanup: (@escaping @MainActor () -> Void) -> Void

    init(registerCleanup: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.registerCleanup = registerCleanup
    }

    /// Runs `cleanup` before the effect's next execution and when it is disposed.
    ///
    /// - Parameter cleanup: Main-actor work that releases the prior side effect.
    public func onCleanup(_ cleanup: @escaping @MainActor () -> Void) {
        registerCleanup(cleanup)
    }
}
