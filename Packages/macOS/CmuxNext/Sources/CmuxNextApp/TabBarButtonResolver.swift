import CmuxNextActions
import CmuxNextSettings
import CmuxNextTabs
import Foundation

/// Turns resolved cmux.json button specs into strip buttons: icon from the
/// spec, else the action's catalog symbol; tooltip is the title plus the
/// action's live shortcut from the registry. Buttons whose action the
/// registry does not know are dropped (and reported by `unknown`).
enum TabBarButtonResolver {
    struct Resolved: Equatable {
        var buttons: [TabStripButton]
        /// Button id -> registry action it runs.
        var actions: [String: ActionID]
        /// Specs whose action is neither in the catalog nor bound.
        var unknown: [TabBarButtonSpec]
    }

    static func resolve(_ specs: [TabBarButtonSpec], registry: ActionRegistry) -> Resolved {
        var result = Resolved(buttons: [], actions: [:], unknown: [])
        for spec in specs {
            let id = registry.canonicalID(for: ActionID(rawValue: spec.actionID))
            guard registry.descriptor(for: id) != nil || registry.isBound(id) else {
                result.unknown.append(spec)
                continue
            }
            let title = spec.title ?? registry.title(for: id) ?? spec.id
            let label = spec.tooltip ?? title
            let icon: TabStripButton.Icon = switch spec.icon {
            case .symbol(let name): .symbol(name)
            case .image(let url): .file(url)
            case nil: .symbol(registry.descriptor(for: id)?.symbol ?? "square.dashed")
            }
            let toolTip = registry.shortcutDisplay(for: id).map { Strings.tabBarButtonToolTip(label, shortcut: $0) } ?? label
            result.buttons.append(TabStripButton(id: spec.id, icon: icon, toolTip: toolTip, accessibilityLabel: label))
            result.actions[spec.id] = id
        }
        return result
    }
}
