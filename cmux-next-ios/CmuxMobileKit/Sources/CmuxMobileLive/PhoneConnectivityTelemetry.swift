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
        stats.flushPeriodically()
    }

    /// Sends this phone's stats to the Cloud service at `base` as the signed-in account.
    public func uploadStats(to base: URL, accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        let http = ConnectivityStatsHTTP(base: base, accessToken: accessToken)
        stats.configure(client: .phone(), upload: { body in await http.post(body) })
    }
}

extension ConnectivityStats.Client {
    /// This iPhone app: its version, build, iOS version and channel.
    public static func phone(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> Self {
        let id = bundle.bundleIdentifier ?? ""
        let version = processInfo.operatingSystemVersion
        return Self(
            platform: "ios",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            channel: channel(bundleID: id, receipt: bundle.appStoreReceiptURL?.lastPathComponent)
        )
    }

    /// dev for a debug or tagged build, testflight for a sandbox receipt, else production.
    static func channel(bundleID: String, receipt: String?) -> String {
        #if DEBUG
        return "dev"
        #else
        if bundleID.hasPrefix("dev.") || bundleID.contains(".debug") || bundleID.contains(".dev.") { return "dev" }
        if receipt == "sandboxReceipt" { return "testflight" }
        return "production"
        #endif
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
