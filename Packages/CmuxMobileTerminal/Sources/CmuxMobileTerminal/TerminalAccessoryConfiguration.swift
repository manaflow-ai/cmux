import CmuxMobileTerminalKit
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
    // Read from the UIKit input-accessory build path inside the off-limits
    // surface/input view; the only two readers are TerminalInputTextView's
    // accessory builder and TerminalShortcutsSettingsView.
    // TRANSITIONAL — construction-at-root injection lands with the GhosttySurfaceView UI-god-object split.
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

    /// Pure reducer that owns the load/merge/forward-compat, toggle, reorder, and
    /// reset logic over the configurable actions' raw identifiers. Lives in
    /// `CmuxMobileTerminalKit` so it is testable from `swift test`; this type is
    /// the thin `@Observable` + persistence shell around it.
    private let reducer = TerminalAccessoryLayoutReducer(
        configurable: TerminalInputAccessoryAction.configurableActions.map(\.rawValue),
        defaultOrder: TerminalInputAccessoryAction.defaultConfigurableOrder.map(\.rawValue)
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let layout = reducer.load(
            savedOrder: defaults.array(forKey: Self.orderDefaultsKey) as? [Int] ?? [],
            savedEnabled: defaults.array(forKey: Self.enabledDefaultsKey) as? [Int]
        )
        displayOrder = layout.order.compactMap(TerminalInputAccessoryAction.init(rawValue:))
        enabledSet = Set(layout.enabled.compactMap(TerminalInputAccessoryAction.init(rawValue:)))
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

    /// Snapshot of the live state in the reducer's raw-identifier vocabulary.
    private var currentLayout: TerminalAccessoryLayoutReducer.Layout {
        TerminalAccessoryLayoutReducer.Layout(
            order: displayOrder.map(\.rawValue),
            enabled: Set(enabledSet.map(\.rawValue))
        )
    }

    /// Project a reducer layout back onto the `@Observable` stored properties.
    private func apply(_ layout: TerminalAccessoryLayoutReducer.Layout) {
        displayOrder = layout.order.compactMap(TerminalInputAccessoryAction.init(rawValue:))
        enabledSet = Set(layout.enabled.compactMap(TerminalInputAccessoryAction.init(rawValue:)))
    }

    /// Show or hide `action`. No-op for non-configurable actions.
    public func setEnabled(_ action: TerminalInputAccessoryAction, _ isEnabled: Bool) {
        guard action.isUserConfigurable else { return }
        apply(reducer.setEnabled(action.rawValue, isEnabled, in: currentLayout))
        persistAndNotify()
    }

    /// Reorder the configurable actions. `offsets`/`destination` are indices
    /// into ``displayOrder`` (the SwiftUI `onMove` contract).
    public func moveActions(from offsets: IndexSet, to destination: Int) {
        apply(reducer.move(from: offsets, to: destination, in: currentLayout))
        persistAndNotify()
    }

    /// Restore the default order (enum order) with every shortcut shown.
    public func resetToDefaults() {
        apply(reducer.defaultLayout())
        persistAndNotify()
    }

    private func persistAndNotify() {
        defaults.set(displayOrder.map(\.rawValue), forKey: Self.orderDefaultsKey)
        defaults.set(displayOrder.filter { enabledSet.contains($0) }.map(\.rawValue), forKey: Self.enabledDefaultsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
