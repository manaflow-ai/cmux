public import Foundation
import os

/// Release diagnostics contain lifecycle metadata only, never workspace content.
@MainActor
@_spi(CmuxHostTransport) public enum CMUXSidebarRecoveryDiagnostics {
    /// Notification consumed only by the selected hosted provider.
    public static let reconnectNotification = Notification.Name("cmux.extension.sidebar.reconnect")
    private static let key = "cmuxExtensionSidebar.lifecycle.v1"
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "SidebarExtensionLifecycle")
    private static var hosts: [UUID: [String: Any]] = [:]

    /// Records a lifecycle event without workspace data.
    public static func record(hostID: UUID, bundleID: String, identityID: String, generation: UInt64,
                       event: String, state: String?, code: Int?) {
        var entry: [String: Any] = [
            "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "host_id": hostID.uuidString, "bundle_id": bundleID,
            "identity_id": identityID, "generation": generation, "event": event,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]
        if let code { entry["error_code"] = code }
        var host = hosts[hostID] ?? [:]
        host.merge(entry) { _, new in new }
        host["state"] = state ?? host["state"] ?? "connecting"
        hosts[hostID] = host
        if let state { entry["state"] = state }
        append(entry)
    }

    /// Records a transport error code, without its possibly sensitive description.
    public static func transportError(generation: UInt64, code: Int) {
        append(["timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
                "pid": ProcessInfo.processInfo.processIdentifier,
                "event": "xpc_proxy_error", "generation": generation, "error_code": code])
    }

    private static func append(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        logger.notice("\(line, privacy: .public)")
        var history = UserDefaults.standard.stringArray(forKey: key) ?? []
        history.append(line)
        UserDefaults.standard.set(Array(history.suffix(100)), forKey: key)
    }

    /// Removes a dismantled host from live status.
    public static func remove(_ hostID: UUID) { hosts[hostID] = nil }
    /// Returns the last one hundred lifecycle events for local support.
    public static func report() -> String { (UserDefaults.standard.stringArray(forKey: key) ?? []).joined(separator: "\n") }

    /// Returns metadata for live hosts of the selected provider.
    public static func status() -> [String: Any] {
        let selected = UserDefaults.standard.string(forKey: "cmuxExtensionSidebar.selectedExtensionBundleId")
        let selectedHosts = hosts.values.filter { ($0["bundle_id"] as? String) == selected }
        return ["selected_bundle_id": selected as Any? ?? NSNull(),
                "hosts": Array(selectedHosts),
                "connected": !selectedHosts.isEmpty && selectedHosts.allSatisfy { ($0["state"] as? String) == "connected" }]
    }

    /// Requests recovery only for the currently selected, hosted provider.
    /// - Parameter bundleID: Optional selected bundle identifier to match.
    /// - Returns: Whether a live selected host accepted the request.
    public static func reconnect(bundleID: String?) -> Bool {
        guard let selected = UserDefaults.standard.string(forKey: "cmuxExtensionSidebar.selectedExtensionBundleId"),
              bundleID == nil || bundleID == selected,
              hosts.values.contains(where: { ($0["bundle_id"] as? String) == selected }) else { return false }
        NotificationCenter.default.post(name: reconnectNotification, object: nil)
        return true
    }
}
