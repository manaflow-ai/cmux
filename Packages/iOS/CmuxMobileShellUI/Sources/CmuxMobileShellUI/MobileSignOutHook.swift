/// Two-phase local-first teardown composed by the iOS app root.
public struct MobileSignOutHook: Sendable {
    /// Server teardown that receives auth's tokens captured before local clear.
    public typealias ServerTeardown = @Sendable (
        _ accessToken: String?,
        _ refreshToken: String?
    ) async -> Void

    private let beginClosure: @MainActor @Sendable () -> ServerTeardown

    /// Creates a sign-out hook.
    ///
    /// - Parameter begin: Fences local resources synchronously, then returns
    ///   the bounded best-effort teardown for auth's captured tokens.
    public init(
        begin: @escaping @MainActor @Sendable () -> ServerTeardown = {
            { _, _ in }
        }
    ) {
        beginClosure = begin
    }

    /// Fences local teardown before auth destroys its token store.
    ///
    /// The returned work may await local cleanup, but auth clears its local
    /// session before running it and bounds it with the remote teardown timer.
    @MainActor
    public func begin() -> ServerTeardown {
        beginClosure()
    }
}
