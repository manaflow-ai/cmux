public import CmuxNextActions
public import CmuxNextDesign

/// One Debug Settings switch as a palette pair, Show / Hide (Lawrence 2026-11-02 on the host pressure
/// warning: "can be enabled in cmd shift p"), as Enable / Disable Channels pair one setting. A run sets
/// the switch the way its Debug Settings row does: the default value removes the override. The change
/// is the store's, made in the run's turn; whatever reads the tunable follows the store's Observation.
/// Both actions are `isDebugOnly` in the catalog: the store is active in DEV and NIGHTLY only.
@MainActor public struct DebugTunableSwitchActions {
    public let show: ActionID
    public let hide: ActionID
    public let tunable: Tunable<Bool>
    public let store: TunableStore

    public init(show: ActionID, hide: ActionID, tunable: Tunable<Bool>, store: TunableStore = .shared) {
        self.show = show
        self.hide = hide
        self.tunable = tunable
        self.store = store
    }

    /// Sets the switch to `on` (a run that changes nothing writes nothing).
    public func set(_ on: Bool) {
        guard tunable.value(in: store) != on else { return }
        if on == tunable.defaultValue { store.reset([tunable.key]) } else { store.set(tunable.key, on.tunableValue) }
    }

    public func bind(into registry: ActionRegistry) {
        for (id, on) in [(show, true), (hide, false)] {
            registry.bindEffect(id) { _ in
                set(on)
                return .done
            }
        }
    }
}
