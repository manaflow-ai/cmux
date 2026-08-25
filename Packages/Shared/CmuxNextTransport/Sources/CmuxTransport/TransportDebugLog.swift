import Foundation
import os

/// Package-internal diagnostics switch and loggers for the next transport.
///
/// Every state transition, decision, and denial in this package logs through
/// these so a transport incident is root-causable from logs alone. Lines are
/// `.notice` (persisted by default) for transitions/decisions and `.error`
/// for failures — never `.info`, which the log store drops.
///
/// The flag is a compile-time constant: `true` only in DEBUG, so release
/// builds of future consumers compile every gated line out and the package
/// never spams them.
enum TransportDebugLog {
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

    /// ReconnectOwner, IrohPeerConnection, substrate, client connect.
    static let core = Logger(subsystem: subsystem, category: "next-transport-core")
    /// TransportHost: admission, sessions, expiry, credential pushes.
    static let host = Logger(subsystem: subsystem, category: "next-transport-host")
    /// BrokerCredentialClient: credential minting.
    static let broker = Logger(subsystem: subsystem, category: "next-transport-broker")

    /// Stable short id correlating one live object across lines.
    static func id(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFF_FFFF, radix: 16)
    }

    /// 8-char prefix of a device/mac/session id.
    static func prefix(_ value: String?) -> String {
        guard let value else { return "-" }
        return String(value.prefix(8))
    }

    /// 8 hex chars (4 bytes) of a key/id blob.
    static func hex8(_ data: Data?) -> String {
        guard let data else { return "-" }
        return data.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Elapsed whole milliseconds since `start`.
    static func ms(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Int64(elapsed.components.seconds) * 1_000
            + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
