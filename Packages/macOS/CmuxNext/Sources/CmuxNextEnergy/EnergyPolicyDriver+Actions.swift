public import CmuxNextActions

/// Energy Saver's session actions (plans/cmux-next/chrome-parity/p14-energy.md, D): each changes the
/// policy in the input's turn and returns `.done`, with no await, no I/O and no daemon.
///
/// As in Chrome's battery saver bubble (chrome/browser/ui/views/performance_controls/
/// battery_saver_bubble_view.cc), "Turn Off for Now" is offered only while the saver is on, and "Turn On
/// Again" only while ending "Turn Off for Now" would turn the saver back on. The palette hides a row
/// that cannot act (``paletteHiddenActionIDs``); `action.run` returns its ``EnergySaverActionRefusal``.
extension EnergyPolicyDriver {
    /// Binds ``EnergySaverAction/turnOffForNow`` and ``EnergySaverAction/turnOnNow`` to this driver.
    public func bindActions(into registry: ActionRegistry) {
        registry.bindEffect(EnergySaverAction.turnOffForNow.id, unavailable: { [self] in
            refusal(.turnOffForNow)?.reason
        }, effect: { [self] _ in
            turnOffForNow()
            return .done
        })
        registry.bindEffect(EnergySaverAction.turnOnNow.id, unavailable: { [self] in
            refusal(.turnOnNow)?.reason
        }, effect: { [self] _ in
            turnOnNow()
            return .done
        })
    }

    /// Why `action` cannot run now, or nil when it can.
    public func refusal(_ action: EnergySaverAction) -> EnergySaverActionRefusal? {
        guard isEnabled else { return .featureOff }
        switch action {
        case .turnOffForNow:
            return source.policy.isSaver ? nil : .saverIsOff
        case .turnOnNow:
            guard isOffForSession else { return .notTurnedOff }
            return saverReasonWithoutHold == nil ? .wouldStayOff : nil
        }
    }

    /// The actions the palette leaves out now: each one that cannot act, so neither row shows while the
    /// `energySaver` feature is off. The App reads it each time the palette opens.
    public var paletteHiddenActionIDs: Set<ActionID> {
        Set(EnergySaverAction.allCases.filter { refusal($0) != nil }.map(\.id))
    }
}
