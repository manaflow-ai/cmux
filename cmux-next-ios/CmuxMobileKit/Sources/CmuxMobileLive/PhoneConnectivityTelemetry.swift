public import CmuxConnectivityTelemetry
import Foundation
import os

extension ConnectivityTelemetry {
    /// Starts the iPhone's connectivity recording once per process: the unified log under
    /// `dev.cmux.mobile`, category `connectivity`. Nothing reads an on-disk journal on the phone
    /// any more (Copy Logs was removed; the team's major incidents reach Slack through
    /// ``ConnectivityIncidentReporter``), so none is written, and one left by an older build is
    /// deleted. The audience follows the account through ``setAccount(email:)``; until then it is
    /// ``ConnectivityAudience/everyone``.
    public func startOnPhone() {
        guard PhoneConnectivityStart.claim() else { return }
        Self.removeOldJournal()
        addSink(Self.unifiedLogSink(subsystem: "dev.cmux.mobile"))
    }

    /// Deletes the journal an older build kept in Application Support (and its rolled copy).
    private static func removeOldJournal() {
        let journal = ConnectivityJournal.applicationSupport()
        Task.detached(priority: .utility) {
            for url in [journal.url, journal.previousURL] { try? FileManager.default.removeItem(at: url) }
        }
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
