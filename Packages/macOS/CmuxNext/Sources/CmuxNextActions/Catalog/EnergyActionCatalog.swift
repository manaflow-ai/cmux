// Energy Saver's session actions (plans/cmux-next/chrome-parity/p14-energy.md, D): "Turn Off Energy
// Saver for Now" and its undo. Chrome's battery saver bubble offers the same "Turn off for now"
// (chrome/browser/ui/views/performance_controls/battery_saver_bubble_view.cc), which calls
// `BatterySaverModeManager::SetTemporaryBatterySaverDisabledForSession`. No default shortcut.
// Titles and refusal reasons live in Localizable.xcstrings.

nonisolated enum EnergyActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        EnergySaverAction.allCases.map(\.descriptor)
    }
}

/// One of Energy Saver's session actions. The `cmux energy` CLI group and MCP offer
/// both, with the palette: the design's CLI/MCP parity (p14-energy.md, D).
public nonisolated enum EnergySaverAction: CaseIterable, Sendable, Hashable {
    /// `energy.saver.turnOffForNow`: holds the saver off until the battery -> AC edge or a change of
    /// `energy.saver`.
    case turnOffForNow
    /// `energy.saver.turnOnNow`: ends that hold before its edge.
    case turnOnNow

    /// The catalog id.
    public var id: ActionID {
        switch self {
        case .turnOffForNow: "energy.saver.turnOffForNow"
        case .turnOnNow: "energy.saver.turnOnNow"
        }
    }

    var descriptor: ActionDescriptor {
        let keywords = ["energy", "saver", "battery", "power", "low power", "efficiency"]
        return switch self {
        case .turnOffForNow:
            make(
                title: String(localized: "action.energy.saver.turnOffForNow", defaultValue: "Turn Off Energy Saver for Now",
                              bundle: .module),
                symbol: "leaf", keywords: keywords + ["off", "disable", "pause", "for now"], cli: "energy turn-off-for-now")
        case .turnOnNow:
            make(
                title: String(localized: "action.energy.saver.turnOnNow", defaultValue: "Turn On Energy Saver Again",
                              bundle: .module),
                symbol: "leaf.fill", keywords: keywords + ["on", "enable", "resume", "again"], cli: "energy turn-on")
        }
    }

    /// An app-wide palette action that the CLI and MCP offer too. Category `.settings`: the palette's
    /// "Settings and Help" section, next to the `energy.saver` setting these actions hold off.
    private func make(title: String, symbol: String, keywords: [String], cli: String) -> ActionDescriptor {
        ActionDescriptor(id: id, title: title, keywords: keywords, category: .settings, symbol: symbol, surfaces: [.palette],
                         cliName: cli, surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject))
    }
}

/// Why an Energy Saver session action cannot run now: the palette row's subtitle and the reason
/// `action.run` (CLI, socket, MCP) returns.
public nonisolated enum EnergySaverActionRefusal: Sendable, Hashable {
    /// The `energySaver` feature is off, so the saver never turns on.
    case featureOff
    /// "Turn Off for Now": the saver is not on now.
    case saverIsOff
    /// "Turn On Again": no "Turn Off for Now" holds.
    case notTurnedOff
    /// "Turn On Again": the hold is set, but the setting and the power inputs would leave the saver off.
    case wouldStayOff

    /// The localized reason.
    public var reason: String {
        switch self {
        case .featureOff:
            String(localized: "action.energy.saver.unavailable.featureOff",
                   defaultValue: "Energy Saver is a Labs feature that is turned off.", bundle: .module)
        case .saverIsOff:
            String(localized: "action.energy.saver.unavailable.saverIsOff",
                   defaultValue: "Energy Saver is not on now.", bundle: .module)
        case .notTurnedOff:
            String(localized: "action.energy.saver.unavailable.notTurnedOff",
                   defaultValue: "Energy Saver was not turned off for now.", bundle: .module)
        case .wouldStayOff:
            String(localized: "action.energy.saver.unavailable.wouldStayOff",
                   defaultValue: "Energy Saver would stay off: its setting does not turn it on now.", bundle: .module)
        }
    }
}
