public import Foundation

/// External effects required by the shared control owner.
public struct V2ControlDependencies: Sendable {
    let connect: @Sendable (URLRequest) async throws -> any V2ControlSocket
    let stackAccessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    let sign: @Sendable (Data) async throws -> Data
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let jitter: @Sendable () -> Double

    /// Injects real network/auth/signing effects or deterministic test replacements.
    /// - Parameters:
    ///   - connect: Opens the socket with the supplied complete handshake.
    ///   - stackAccessToken: Preserves existing Stack auth and coalesces refresh at the service boundary.
    ///   - sign: Signs canonical bytes with the same fresh v2 key used by IROH.
    ///   - now: Wall clock for token expiry and server proofs.
    ///   - sleep: Cancellable clock delay used only for deadlines and renewal/backoff.
    ///   - jitter: A value in `0...1` to spread retries across clients.
    public init(
        connect: @escaping @Sendable (URLRequest) async throws -> any V2ControlSocket,
        stackAccessToken: @escaping @Sendable (Bool) async throws -> String,
        sign: @escaping @Sendable (Data) async throws -> Data,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(max(0, seconds)))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.connect = connect
        self.stackAccessToken = stackAccessToken
        self.sign = sign
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
    }
}
