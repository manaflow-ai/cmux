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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var featureFlagsObserver: NSObjectProtocol?
    @ObservationIgnored private let discoverBootedDevice: @Sendable () async -> Bool

    init(discoverBootedDevice: (@Sendable () async -> Bool)? = nil) {
        if let discoverBootedDevice {
            self.discoverBootedDevice = discoverBootedDevice
        } else {
            // One service reused across samples; discovery shells out to
            // `simctl`, so per-refresh construction would rebuild its plumbing
            // on every app activation.
            let service = SimulatorControlService()
            self.discoverBootedDevice = {
                let devices = (try? await service.discoverDevices()) ?? []
                return devices.contains { $0.isAvailable && $0.state == .booted }
            }
        }
        // The launch-time refresh runs before the remote flags load; when the
        // simulator flag flips on afterward, sample immediately so the
        // contextual button can appear without waiting for a reactivation.
        featureFlagsObserver = NotificationCenter.default.addObserver(
            forName: .cmuxFeatureFlagsDidChange,
            object: CmuxFeatureFlags.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        if let featureFlagsObserver {
            NotificationCenter.default.removeObserver(featureFlagsObserver)
        }
    }

    /// Samples `simctl` for a fresh authoritative answer. Single-flight so
    /// activation churn cannot stack device discoveries, but never served
    /// from a time-based cache: this is UI-enabling state, and a stale
    /// `false` would hide the contextual button right after the user booted
    /// a Simulator. Posts
    /// ``Notification/Name/cmuxSimulatorBootPresenceDidChange`` only when
    /// the answer flips.
    func refresh() {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else { return }
        guard refreshTask == nil else { return }
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
