public import CmuxNextActions

/// Energy Saver's session actions (plans/cmux-next/chrome-parity/p14-energy.md, D): each changes the
/// policy in the input's turn and returns `.done`, with no await, no I/O and no daemon.
///
/// As in Chrome's battery saver bubble (chrome/browser/ui/views/performance_controls/
/// battery_saver_bubble_view.cc), "Turn Off for Now" is offered only while the saver is on, and "Turn On
/// Again" only while "Turn Off for Now" holds.
extension EnergyPolicyDriver {
    /// Binds `energy.saver.turnOffForNow` and `energy.saver.turnOnNow` to this driver.
    public func bindActions(into registry: ActionRegistry) {
        registry.bindEffect("energy.saver.turnOffForNow", isEnabled: { [self] in
            isEnabled && source.policy.isSaver
        }, effect: { [self] _ in
            turnOffForNow()
            return .done
        })
        registry.bindEffect("energy.saver.turnOnNow", isEnabled: { [self] in isOffForSession }, effect: { [self] _ in
            turnOnNow()
            return .done
        })
    }
}
