public import Foundation

/// One timed stage of the stored-Mac reconnect preamble (claim → first dial).
///
/// `offset` is measured on `ContinuousClock` from the generation claim, so a
/// stage whose offset jumps names a slow awaited operation and uniformly
/// stretched small offsets name executor starvation. The composite keeps the
/// latest timeline as a value so a headless test can assert the claim→dial
/// bound on the real preamble; the device debug log is only a second consumer.
public struct StoredMacReconnectPreambleStage: Sendable, Equatable {
    public let name: String
    public let offset: Duration
    public let generation: Int

    public var offsetMilliseconds: Double {
        Double(offset.components.seconds) * 1_000
            + Double(offset.components.attoseconds) / 1e15
    }
}
