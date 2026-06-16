import Foundation
import Observation

/// `@Observable` view-model that projects the host's live iOS pairing status
/// into SwiftUI-readable state for the Mobile settings section.
///
/// The status (actual bound port, ephemeral-fallback flag, connection count,
/// routes) is host-app runtime state, not a catalog setting, so it arrives
/// through ``SettingsHostActions`` rather than ``DefaultsValueModel``:
///
/// 1. On construction it seeds ``current`` from
///    ``SettingsHostActions/mobilePairingStatus()``.
/// 2. It subscribes to ``SettingsHostActions/mobilePairingStatusUpdates()`` via
///    a ``SettingReadDriver`` so the bound port and connection count stay live
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

    @ObservationIgnored private let driver = SettingReadDriver<MobilePairingStatusSnapshot>()

    /// Creates a model bound to the host's pairing-status stream.
    ///
    /// - Parameter hostActions: The host bridge that supplies the current
    ///   status and a change stream.
    init(hostActions: SettingsHostActions) {
        current = hostActions.mobilePairingStatus()
        driver.activate({ hostActions.mobilePairingStatusUpdates() }) { [weak self] snapshot in
            self?.current = snapshot
        }
    }
}
