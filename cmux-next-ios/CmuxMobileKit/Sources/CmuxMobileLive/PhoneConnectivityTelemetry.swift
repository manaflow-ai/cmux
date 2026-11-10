public import CmuxConnectivityTelemetry
import Foundation

extension ConnectivityTelemetry {
    /// Starts the iPhone's connectivity recording once per process: its journal
    /// (``ConnectivityJournal/applicationSupport(maxBytes:)``, at most 2 MB on disk; Settings →
    /// Help → Copy Logs includes it) and the unified log under `dev.cmux.mobile`, category
    /// `connectivity`. The audience follows the account through ``setAccount(email:)``; until
    /// then it is ``ConnectivityAudience/everyone``.
    public func startOnPhone() {
        guard PhoneConnectivityStart.claim() else { return }
        setJournal(.applicationSupport())
        addSink(Self.unifiedLogSink(subsystem: "dev.cmux.mobile"))
    }
}

/// ``ConnectivityTelemetry/startOnPhone()`` runs its setup once.
private final class PhoneConnectivityStart: @unchecked Sendable {
    private static let shared = PhoneConnectivityStart()
    private let lock = NSLock()
    private var started = false

    static func claim() -> Bool {
        shared.lock.withLock {
            defer { shared.started = true }
            return !shared.started
        }
    }
}
