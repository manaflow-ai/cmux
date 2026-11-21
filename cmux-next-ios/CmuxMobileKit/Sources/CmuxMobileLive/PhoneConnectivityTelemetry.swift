public import CmuxConnectivityTelemetry
import Foundation
import os

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
private struct PhoneConnectivityStart {
    private static let started = OSAllocatedUnfairLock(initialState: false)

    /// True for the first caller only.
    static func claim() -> Bool {
        started.withLock { started in
            defer { started = true }
            return !started
        }
    }
}
