import Foundation
import os

/// Bridge-module diagnostics switch and logger, mirroring the core target's
/// `TransportDebugLog`: `.notice` for every routing decision (persisted by
/// default), `.error` for failures, and a compile-time flag that is `true`
/// only in DEBUG so release builds of consumers compile every line out.
enum BridgeDebugLog {
    #if DEBUG
    static let enabled = true
    #else
    static let enabled = false
    #endif

    #if os(iOS)
    static let subsystem = "dev.cmux.ios"
    #else
    static let subsystem = "dev.cmux"
    #endif

    /// Bridged lane routing: acceptor ingest, dialer opens, byte transport.
    static let lanes = Logger(subsystem: subsystem, category: "next-transport-bridge-lanes")

    /// Stable short id correlating one live object across lines.
    static func id(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFF_FFFF, radix: 16)
    }

    /// Elapsed whole milliseconds since `start`.
    static func ms(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Int64(elapsed.components.seconds) * 1_000
            + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
