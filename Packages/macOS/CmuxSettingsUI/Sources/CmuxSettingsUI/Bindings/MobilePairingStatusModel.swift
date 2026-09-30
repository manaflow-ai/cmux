import Foundation
import Observation

/// `@Observable` view-model that projects the host's live iOS pairing status
/// into SwiftUI-readable state for the Mobile settings section.
///
/// The status (actual bound port, ephemeral-fallback flag, connection count,
/// routes) is host-app runtime state, not a catalog setting, so it arrives
/// through ``SettingsHostActions`` rather than ``DefaultsValueModel``:
///
/// 1. On construction it keeps ``current`` empty and does not touch the host.
/// 2. ``startObserving()`` seeds ``current`` from
///    ``SettingsHostActions/mobilePairingStatus()`` and subscribes to
///    ``SettingsHostActions/mobilePairingStatusUpdates()`` via a
///    ``SettingReadDriver`` so the bound port and connection count stay live
///    without polling.
///
/// Lifecycle matches ``DefaultsValueModel``: the driver owns the subscription
/// task and cancels it on `deinit`, finishing the stream and tearing down the
/// host's underlying observation.
@MainActor
@Observable
final class MobilePairingStatusModel {
    /// The most recent pairing status, or `nil` when the host has no mobile
    /// service running (or in previews/tests). SwiftUI views read this
    /// synchronously.
    private(set) var current: MobilePairingStatusSnapshot?

    @ObservationIgnored private let currentStatus: () -> MobilePairingStatusSnapshot?
    @ObservationIgnored private let makeStream: () -> AsyncStream<MobilePairingStatusSnapshot>
    @ObservationIgnored private let driver = SettingReadDriver<MobilePairingStatusSnapshot>()
    @ObservationIgnored private var hasStarted = false

    /// Creates a model bound to the host's pairing-status stream.
    ///
    /// - Parameter hostActions: The host bridge that supplies the current
    ///   status and a change stream.
    convenience init(hostActions: SettingsHostActions) {
        self.init(
            currentStatus: { hostActions.mobilePairingStatus() },
            makeStream: { hostActions.mobilePairingStatusUpdates() }
        )
    }

    init(
        currentStatus: @escaping () -> MobilePairingStatusSnapshot?,
        makeStream: @escaping () -> AsyncStream<MobilePairingStatusSnapshot>
    ) {
        self.currentStatus = currentStatus
        self.makeStream = makeStream
        current = nil
    }

    /// Starts the host-status stream for the retained model.
    ///
    /// Idempotent: the first call reads the current status and starts
    /// observation; later calls are ignored by ``SettingReadDriver``.
    func startObserving() {
        guard !hasStarted else { return }
        hasStarted = true
        current = currentStatus()
        driver.activate(makeStream) { [weak self] snapshot in
            self?.current = snapshot
        }
    }
}
