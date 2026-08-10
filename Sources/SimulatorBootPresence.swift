import CmuxSimulator
import Foundation
import Observation

extension Notification.Name {
    /// Posted by ``SimulatorBootPresence`` when the booted-device answer
    /// flips, so each workspace can re-apply its surface tab-bar buttons.
    static let cmuxSimulatorBootPresenceDidChange =
        Notification.Name("cmux.simulatorBootPresenceDidChange")
}

/// App-level answer to "is any iPhone or iPad Simulator booted right now?".
///
/// Sampled at discrete UI moments (launch, app activation) instead of on a
/// timer: a user who just booted a Simulator in Xcode reaches for cmux next,
/// and that switch re-activates the app. The answer drives the contextual
/// New Simulator tab-bar button, so the feature surfaces exactly while the
/// user is doing iOS work and disappears when they are not.
@MainActor
@Observable
final class SimulatorBootPresence {
    private(set) var hasBootedDevice = false
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let minimumRefreshInterval: TimeInterval
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let discoverBootedDevice: @Sendable () async -> Bool

    init(
        minimumRefreshInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init,
        discoverBootedDevice: @escaping @Sendable () async -> Bool = {
            let devices = (try? await SimulatorControlService().discoverDevices()) ?? []
            return devices.contains { $0.isAvailable && $0.state == .booted }
        }
    ) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.now = now
        self.discoverBootedDevice = discoverBootedDevice
    }

    /// Samples `simctl` unless a sufficiently fresh answer exists.
    /// Single-flight and throttled, so activation churn cannot stack device
    /// discoveries. Posts ``Notification/Name/cmuxSimulatorBootPresenceDidChange``
    /// only when the answer flips.
    func refresh() {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else { return }
        guard refreshTask == nil else { return }
        if let lastRefreshAt,
           now().timeIntervalSince(lastRefreshAt) < minimumRefreshInterval {
            return
        }
        lastRefreshAt = now()
        refreshTask = Task { @MainActor [discoverBootedDevice] in
            let booted = await discoverBootedDevice()
            refreshTask = nil
            guard !Task.isCancelled, booted != hasBootedDevice else { return }
            hasBootedDevice = booted
            NotificationCenter.default.post(
                name: .cmuxSimulatorBootPresenceDidChange,
                object: self
            )
        }
    }
}
