import Foundation
import Observation

/// `@Observable` view-model that projects the host's merged computer list
/// (registry + pairings + presence) into SwiftUI-readable state for the
/// Computers settings section.
///
/// Mirrors ``MobilePairingStatusModel``: host runtime state arrives through
/// ``SettingsHostActions`` rather than the settings catalog, seeded once on
/// ``startObserving()`` and kept live by the host's snapshot stream via
/// ``SettingReadDriver`` (which owns the subscription task and cancels it on
/// deinit).
@MainActor
@Observable
final class ComputersListModel {
    /// The most recent snapshot, or `nil` when the host has no computers
    /// directory (previews/tests).
    private(set) var current: ComputersSettingsSnapshot?

    @ObservationIgnored private let currentSnapshot: () -> ComputersSettingsSnapshot?
    @ObservationIgnored private let makeStream: () -> AsyncStream<ComputersSettingsSnapshot>
    @ObservationIgnored private let driver = SettingReadDriver<ComputersSettingsSnapshot>()
    @ObservationIgnored private var hasStarted = false

    /// Creates a model bound to the host's computers stream.
    convenience init(hostActions: SettingsHostActions) {
        self.init(
            currentSnapshot: { hostActions.computersSnapshot() },
            makeStream: { hostActions.computersUpdates() }
        )
    }

    init(
        currentSnapshot: @escaping () -> ComputersSettingsSnapshot?,
        makeStream: @escaping () -> AsyncStream<ComputersSettingsSnapshot>
    ) {
        self.currentSnapshot = currentSnapshot
        self.makeStream = makeStream
        current = nil
    }

    /// Starts the host-snapshot stream for the retained model. Idempotent.
    func startObserving() {
        guard !hasStarted else { return }
        hasStarted = true
        current = currentSnapshot()
        driver.activate(makeStream) { [weak self] snapshot in
            self?.current = snapshot
        }
    }
}
