public import Foundation
import os

/// Stores bounded lifecycle metadata without workspace content or terminal output.
///
/// Construct the store at the host composition root and inject it into every hosted view.
/// Tests use isolated defaults and a fixed timestamp:
///
/// ```swift
/// let diagnostics = CMUXSidebarRecoveryDiagnostics(
///     defaults: defaults, processID: 42, appVersion: "test", appBuild: "1",
///     now: { Date(timeIntervalSince1970: 0) }
/// )
/// ```
@MainActor
@_spi(CmuxHostTransport) public final class CMUXSidebarRecoveryDiagnostics {
    private static let key = "cmuxExtensionSidebar.lifecycle.v1"
    private let defaults: UserDefaults
    private let processID: Int32
    private let appVersion: String
    private let appBuild: String
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "SidebarExtensionLifecycle")
    private var hosts: [UUID: [String: Any]] = [:]
    private var reconnectObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Creates an isolated diagnostic store for one host process.
    /// - Parameters:
    ///   - defaults: Store for the last one hundred metadata events.
    ///   - processID: Host process identifier, never an extension's PID.
    ///   - appVersion: Host version recorded with lifecycle events.
    ///   - appBuild: Host build recorded with lifecycle events.
    ///   - now: Timestamp source; tests supply a deterministic clock.
    public init(defaults: UserDefaults, processID: Int32, appVersion: String, appBuild: String, now: @escaping () -> Date) {
        self.defaults = defaults
        self.processID = processID
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.now = now
    }

    /// Records a host lifecycle event using identifiers and error codes only.
    /// - Parameters:
    ///   - hostID: Stable identifier for this mounted host view.
    ///   - bundleID: Selected extension bundle identifier.
    ///   - identityID: ExtensionKit identity identifier.
    ///   - generation: Mounted host generation.
    ///   - event: Lifecycle event name.
    ///   - state: New host state, or nil to retain the previous state.
    ///   - code: Numeric transport error code, if available.
    public func record(hostID: UUID, bundleID: String, identityID: String, generation: UInt64,
                       event: String, state: String?, code: Int?) {
        var entry = eventMetadata(event)
        entry.merge(["host_id": hostID.uuidString, "bundle_id": bundleID,
                     "identity_id": identityID, "generation": generation]) { _, new in new }
        if let code { entry["error_code"] = code }
        var host = hosts[hostID] ?? [:]
        host.merge(entry) { _, new in new }
        host["state"] = state ?? host["state"] ?? "connecting"
        hosts[hostID] = host
        if let state { entry["state"] = state }
        append(entry)
    }

    /// Records a numeric transport error without its potentially sensitive description.
    /// - Parameters:
    ///   - generation: Transport generation reporting the error.
    ///   - code: Foundation error code.
    public func transportError(generation: UInt64, code: Int) {
        var entry = eventMetadata("xpc_proxy_error")
        entry["generation"] = generation
        entry["error_code"] = code
        append(entry)
    }

    /// Records a provider transition without project or conversation data.
    /// - Parameters:
    ///   - previous: Persisted provider before the transition.
    ///   - current: Persisted provider after the transition.
    ///   - source: Entry point responsible for the change.
    public func providerChanged(previous: String, current: String, source: String) {
        guard previous != current else { return }
        var entry = eventMetadata("provider_changed")
        entry["previous_provider_id"] = previous
        entry["provider_id"] = current
        entry["source"] = source
        append(entry)
    }

    private func eventMetadata(_ event: String) -> [String: Any] {
        ["timestamp_ms": Int64(now().timeIntervalSince1970 * 1000), "pid": processID,
         "event": event, "app_version": appVersion, "app_build": appBuild]
    }

    private func append(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        logger.notice("\(line, privacy: .public)")
        var history = defaults.stringArray(forKey: Self.key) ?? []
        history.append(line)
        defaults.set(Array(history.suffix(100)), forKey: Self.key)
    }

    /// Removes a dismantled host from live status.
    /// - Parameter hostID: Dismantled host identifier.
    public func remove(_ hostID: UUID) { hosts[hostID] = nil }

    /// Returns at most one hundred metadata events for local support.
    /// - Returns: Newline separated JSON lifecycle events.
    public func report() -> String { (defaults.stringArray(forKey: Self.key) ?? []).joined(separator: "\n") }

    /// Returns status for the effective provider, separately from the retained bundle selection.
    /// - Parameters:
    ///   - providerID: Provider actually rendered after feature gates resolve.
    ///   - providerActive: Whether the extension host provider is actually rendered.
    /// - Returns: Provider metadata and current selected hosts; connectivity requires all active hosts to acknowledge.
    public func status(providerID: String, providerActive: Bool) -> [String: Any] {
        let selected = defaults.string(forKey: "cmuxExtensionSidebar.selectedExtensionBundleId")
        let selectedHosts = hosts.values.filter { ($0["bundle_id"] as? String) == selected }
        return ["provider_id": providerID, "provider_active": providerActive,
                "selected_bundle_id": selected as Any? ?? NSNull(), "hosts": Array(selectedHosts),
                "connected": providerActive && !selectedHosts.isEmpty
                    && selectedHosts.allSatisfy { ($0["state"] as? String) == "connected" }]
    }

    /// Subscribes one hosted view to explicit local reconnect requests.
    /// - Returns: A cancellation integrated stream for each live host; overlapping pending requests coalesce into one.
    public func reconnectRequests() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            reconnectObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.reconnectObservers[id] = nil }
            }
        }
    }

    /// Requests recovery while preserving an explicit choice of the classic sidebar.
    /// - Parameters:
    ///   - bundleID: Optional selected bundle identifier to match.
    ///   - providerActive: Whether the extension host provider is actually rendered.
    /// - Returns: Whether a live selected host accepted the request.
    public func reconnect(bundleID: String?, providerActive: Bool) -> Bool {
        guard providerActive,
              let selected = defaults.string(forKey: "cmuxExtensionSidebar.selectedExtensionBundleId"),
              bundleID == nil || bundleID == selected,
              hosts.values.contains(where: { ($0["bundle_id"] as? String) == selected }),
              !reconnectObservers.isEmpty else { return false }
        for observer in reconnectObservers.values { observer.yield(()) }
        return true
    }
}
