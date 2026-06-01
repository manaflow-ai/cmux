import Foundation
import Observation

/// User-editable configuration of which terminal input-accessory shortcut
/// buttons appear, and in what order.
///
/// Only the *insertable* shortcuts are configurable (Esc, Tab, arrows, `$`,
/// `/`, `@`, `^C`, Claude/Codex launchers, …). The modifier keys (⌃ ⌥ ⌘) and
/// the zoom controls are structural and always pinned at the front of the bar,
/// so reconfiguring shortcuts never disturbs the armed-modifier machinery.
///
/// This is the single source of truth for the bar's configurable region. It
/// persists to `UserDefaults`, is `@Observable` for the SwiftUI editor, and
/// posts ``didChangeNotification`` so the UIKit toolbar can rebuild live.
@MainActor
@Observable
public final class TerminalAccessoryConfiguration {
    /// Shared instance backing the live toolbar and the settings editor.
    public static let shared = TerminalAccessoryConfiguration()

    /// Posted (on the main thread) whenever the configuration changes, so the
    /// UIKit input-accessory bar can rebuild its configurable buttons.
    public static let didChangeNotification = Notification.Name("cmux.terminal.accessoryConfigurationDidChange")

    private static let orderDefaultsKey = "cmux.terminal.accessory.displayOrder.v1"
    private static let enabledDefaultsKey = "cmux.terminal.accessory.enabled.v1"

    /// The configurable actions in the order the user has arranged them. Always
    /// contains exactly the configurable actions (new actions added to the enum
    /// in a later build are appended automatically).
    public private(set) var displayOrder: [TerminalInputAccessoryAction]

    /// The subset of ``displayOrder`` that is currently shown on the bar.
    public private(set) var enabledSet: Set<TerminalInputAccessoryAction>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let all = TerminalInputAccessoryAction.configurableActions

        // Load saved order, drop unknown raw values, append any configurable
        // action not yet persisted (forward-compat when the enum grows).
        let savedOrder = (defaults.array(forKey: Self.orderDefaultsKey) as? [Int] ?? [])
            .compactMap(TerminalInputAccessoryAction.init(rawValue:))
            .filter { $0.isUserConfigurable }
        var order = savedOrder
        var seen = Set(savedOrder)
        for action in all where !seen.contains(action) {
            order.append(action)
            seen.insert(action)
        }
        displayOrder = order

        if let savedEnabled = defaults.array(forKey: Self.enabledDefaultsKey) as? [Int] {
            enabledSet = Set(
                savedEnabled
                    .compactMap(TerminalInputAccessoryAction.init(rawValue:))
                    .filter { $0.isUserConfigurable }
            )
        } else {
            // First launch: every configurable shortcut is shown by default.
            enabledSet = Set(all)
        }
    }

    /// The enabled actions in display order; this is exactly what the toolbar's
    /// configurable region renders, after the pinned modifier/zoom buttons.
    public var enabledActions: [TerminalInputAccessoryAction] {
        displayOrder.filter { enabledSet.contains($0) }
    }

    /// Whether `action` is currently shown on the bar.
    public func isEnabled(_ action: TerminalInputAccessoryAction) -> Bool {
        enabledSet.contains(action)
    }

    /// Show or hide `action`. No-op for non-configurable actions.
    public func setEnabled(_ action: TerminalInputAccessoryAction, _ isEnabled: Bool) {
        guard action.isUserConfigurable else { return }
        if isEnabled { enabledSet.insert(action) } else { enabledSet.remove(action) }
        persistAndNotify()
    }

    /// Reorder the configurable actions. `offsets`/`destination` are indices
    /// into ``displayOrder`` (the SwiftUI `onMove` contract).
    public func moveActions(from offsets: IndexSet, to destination: Int) {
        displayOrder.move(fromOffsets: offsets, toOffset: destination)
        persistAndNotify()
    }

    /// Restore the default order (enum order) with every shortcut shown.
    public func resetToDefaults() {
        displayOrder = TerminalInputAccessoryAction.configurableActions
        enabledSet = Set(displayOrder)
        persistAndNotify()
    }

    private func persistAndNotify() {
        defaults.set(displayOrder.map(\.rawValue), forKey: Self.orderDefaultsKey)
        defaults.set(displayOrder.filter { enabledSet.contains($0) }.map(\.rawValue), forKey: Self.enabledDefaultsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
