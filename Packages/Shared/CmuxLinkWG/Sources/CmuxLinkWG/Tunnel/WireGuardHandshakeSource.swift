import CryptoKit
public import Foundation

/// Where a tunnel gets its ephemeral keys, session indices and wall-clock
/// timestamps. Random and the system clock in production; fixed in the
/// golden-vector tests.
public struct WireGuardHandshakeSource: Sendable {
    let makeEphemeral: @Sendable () -> WireGuardPrivateKey
    let makeIndex: @Sendable () -> UInt32
    let now: @Sendable () -> Date

    public init(
        makeEphemeral: @escaping @Sendable () -> WireGuardPrivateKey = { WireGuardPrivateKey() },
        makeIndex: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 1...UInt32.max) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeEphemeral = makeEphemeral
        self.makeIndex = makeIndex
        self.now = now
    }
}
