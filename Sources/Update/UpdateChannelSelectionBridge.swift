import CmuxSettings
import CmuxUpdater
import Foundation

/// Bridges the `updates.channel` setting into the updater and analytics.
///
/// Owns the single observation of the JSON store for that key: it keeps the latest value for
/// synchronous feed resolution, and calls `onChange` for every later change so the
/// composition root can trigger an update check. `CmuxUpdater` never sees the settings
/// package; it only receives ``feedSelection`` through its provider closure.
@MainActor
final class UpdateChannelSelectionBridge {
    private let store: JSONConfigStore
    private let key: JSONKey<UpdateChannel>
    /// The most recently observed channel; seeded from disk so the first feed resolution is right.
    private(set) var current: UpdateChannel
    private var observation: Task<Void, Never>?

    /// - Parameters:
    ///   - store: The cmux.json store that persists the selection.
    ///   - key: The catalog key; defaults to `updates.channel`.
    ///   - onChange: Called on the main actor with each new value after the seeded one.
    init(
        store: JSONConfigStore,
        key: JSONKey<UpdateChannel> = SettingCatalog().updates.channel,
        onChange: @escaping @MainActor (UpdateChannel) -> Void
    ) {
        self.store = store
        self.key = key
        self.current = store.snapshotValue(for: key)
        observation = Task { @MainActor [weak self] in
            for await value in store.values(for: key) {
                guard let self else { return }
                let changed = value != self.current
                self.current = value
                if changed {
                    onChange(value)
                }
            }
        }
    }

    deinit {
        observation?.cancel()
    }

    /// The selection handed to ``UpdateFeedResolver`` through ``UpdateController``.
    var feedSelection: UpdateChannelSelection {
        switch current {
        case .stable: .stable
        case .rc: .rc
        }
    }
}
