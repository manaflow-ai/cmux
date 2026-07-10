/// Two-phase local-first teardown composed by the iOS app root.
public struct MobileSignOutHook: Sendable {
    /// Server teardown that receives auth's tokens captured before local clear.
    public typealias ServerTeardown = @Sendable (
        _ accessToken: String?,
        _ refreshToken: String?
    ) async -> Void

    private let prepareClosure: @Sendable () async -> ServerTeardown

    /// Creates a sign-out hook.
    ///
    /// - Parameter prepare: Performs local resource and cache teardown, then
    ///   returns the bounded best-effort server teardown for captured tokens.
    public init(
        prepare: @escaping @Sendable () async -> ServerTeardown = {
            { _, _ in }
        }
    ) {
        prepareClosure = prepare
    }

    /// Completes local preparation before auth destroys its token store.
    ///
    /// - Returns: The remote teardown auth runs with captured credentials.
    public func prepare() async -> ServerTeardown {
        await prepareClosure()
    }
}
