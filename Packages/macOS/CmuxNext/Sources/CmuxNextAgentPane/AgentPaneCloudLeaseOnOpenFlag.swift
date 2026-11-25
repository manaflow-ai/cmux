import Foundation

/// `CLOUD_LEASE_ON_OPEN`, the launch flag for leasing a warm Cloud machine when a composer opens with
/// Cloud already its target (a remembered Cloud pick, or New Tab on a Cloud pane), before any key
/// (webviews cloudComposeReservation.ts `opened`). Read from the bundle's `LSEnvironment`, else the
/// launch environment; the bundle's value wins. On by default (Leo 2026-11-25: "it doesnt work if it's not
/// \"on by default\""): `0` or `false` is the kill switch. It
/// reaches the page as the `composer` event's `cloudLeaseOnOpen`, and the pane takes its one
/// no-gesture reserve per shown New Tab page only while it is on (``AgentPaneModel/takeCloudOpenLease(_:)``).
public nonisolated struct AgentPaneCloudLeaseOnOpenFlag: Sendable, Equatable {
    public static let key = "CLOUD_LEASE_ON_OPEN"
    public let enabled: Bool

    public init(bundled: [String: String]?, environment: [String: String]) {
        let value = (bundled?[Self.key] ?? environment[Self.key])?.trimmingCharacters(in: .whitespaces).lowercased()
        enabled = !(value == "0" || value == "false")
    }

    /// The running app's flag, read once: a launch flag does not change while the app runs.
    public static let current = AgentPaneCloudLeaseOnOpenFlag(
        bundled: Bundle.main.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String],
        environment: ProcessInfo.processInfo.environment)
}
