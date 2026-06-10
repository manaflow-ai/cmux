import Foundation
@preconcurrency import Network

/// Watches the system network path for the mobile pairing host and reports
/// deduplicated path changes on the main actor.
///
/// The pairing listener stays bound when the Mac moves networks or Tailscale
/// flips, so the advertised route set (and the team device registry that
/// ``DeviceRegistryClient`` mirrors from `statusUpdates()`) needs an explicit
/// trigger to refresh; ``MobileHostService`` owns the republish action and
/// this type owns the observation: one `NWPathMonitor`, a path signature for
/// duplicate suppression, and nothing else.
///
/// Every observation that differs from the previous one fires `onPathChange`,
/// *including the first*: the initial callback can arrive after the
/// listener-ready route publish and describe a different path than those
/// routes were computed on (e.g. Tailscale came up in between), so treating
/// it as a silent baseline would swallow that first real change. Republishing
/// is cheap because downstream consumers dedup unchanged routes; only an
/// observation identical to the previous one is skipped (`NWPathMonitor` can
/// deliver duplicate callbacks).
@MainActor
final class MobileHostNetworkPathMonitor {
    private let monitor = NWPathMonitor()
    /// Signature of the last observed path, for duplicate suppression.
    private var lastSignature: String?
    private let onPathChange: @MainActor () -> Void

    init(onPathChange: @escaping @MainActor () -> Void) {
        self.onPathChange = onPathChange
    }

    /// Begin observing. The handler computes the signature off-main (on
    /// `queue`) and hops to the main actor for dedup state and the callback.
    func start(queue: DispatchQueue) {
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.signature(
                status: String(describing: path.status),
                interfaceNames: path.availableInterfaces.map(\.name),
                gateways: path.gateways.map { String(describing: $0) }
            )
            Task { @MainActor [weak self] in
                self?.handleObservation(signature: signature)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private func handleObservation(signature: String) {
        let changed = Self.shouldReportPathChange(
            previousSignature: lastSignature,
            newSignature: signature
        )
        lastSignature = signature
        guard changed else { return }
        onPathChange()
    }

    /// Stable identity of a network path for change detection. Order-insensitive
    /// over interfaces and gateways so enumeration order can't fake a change.
    /// Pure for tests.
    nonisolated static func signature(
        status: String,
        interfaceNames: [String],
        gateways: [String]
    ) -> String {
        let interfaces = interfaceNames.sorted().joined(separator: ",")
        let gatewayList = gateways.sorted().joined(separator: ",")
        return "\(status)|\(interfaces)|\(gatewayList)"
    }

    /// Whether a path observation should be reported: any observation that
    /// differs from the previous one, including the first (see the type doc
    /// for why the first observation is not a silent baseline). Pure for tests.
    nonisolated static func shouldReportPathChange(
        previousSignature: String?,
        newSignature: String
    ) -> Bool {
        previousSignature != newSignature
    }
}
