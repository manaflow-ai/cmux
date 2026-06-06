import CmuxMobileTerminalKit
import Foundation
import Observation

/// User-editable configuration of the terminal input-accessory bar's
/// configurable region: which shortcut buttons appear, in what order, and any
/// user-defined ``CustomToolbarAction``s.
///
/// The bar has two regions. The leading region (the ⌃ ⌥ ⌘ ⇧ modifier keys and
/// the zoom controls) is structural and always pinned at the front, so
/// reconfiguring never disturbs the armed-modifier machinery and is not modeled
/// here. The trailing region is configurable: the shipped built-in shortcuts
/// (Esc, Tab, arrows, the agent launchers, …) plus any custom actions, ordered
/// and toggled together and keyed by ``ToolbarItemID``.
///
/// This is the single source of truth for that region. It persists to
/// `UserDefaults`, is `@Observable` for the SwiftUI editor, and posts
/// ``didChangeNotification`` so the UIKit toolbar can rebuild live.
@MainActor
@Observable
public final class TerminalAccessoryConfiguration {
    /// Shared instance backing the live toolbar and the settings editor.
    // Read from the UIKit input-accessory build path inside the off-limits
    // surface/input view; readers are TerminalInputTextView's accessory builder
    // and the shortcuts settings editor.
    // TRANSITIONAL — construction-at-root injection lands with the
    // GhosttySurfaceView UI-god-object split.
    public static let shared = TerminalAccessoryConfiguration()

    /// Posted (on the main thread) whenever the configuration changes, so the
    /// UIKit input-accessory bar can rebuild its configurable buttons.
    public static let didChangeNotification = Notification.Name("cmux.terminal.accessoryConfigurationDidChange")

    // v2 schema, keyed by ``ToolbarItemID`` storage keys + JSON custom actions.
    private static let orderDefaultsKey = "cmux.terminal.toolbar.order.v2"
    private static let enabledDefaultsKey = "cmux.terminal.toolbar.enabled.v2"
    private static let customDefaultsKey = "cmux.terminal.toolbar.custom.v2"
    // v1 schema (parallel [Int] arrays of built-in rawValues), read once to
    // forward-migrate an upgrading user's existing arrangement.
    private static let legacyOrderDefaultsKey = "cmux.terminal.accessory.displayOrder.v1"
    private static let legacyEnabledDefaultsKey = "cmux.terminal.accessory.enabled.v1"

    /// The configurable items in the order the user has arranged them, as unified
    /// identifiers (built-ins and custom actions together).
    public private(set) var displayOrder: [ToolbarItemID]

    /// The subset of ``displayOrder`` currently shown on the bar.
    public private(set) var enabledSet: Set<ToolbarItemID>

    /// The user-defined custom actions, in their canonical (append) order.
    public private(set) var customActions: [CustomToolbarAction]

    @ObservationIgnored private let defaults: UserDefaults
    // Rebuilt whenever the custom-action set changes, so the configurable id list
    // (built-ins + customs) stays in sync. The curated built-in default order
    // from `TerminalInputAccessoryAction.defaultConfigurableOrder` is threaded
    // through `makeReducer` so a fresh install gets the redesigned bar layout.
    @ObservationIgnored private var reducer: TerminalAccessoryLayoutReducer<ToolbarItemID>
    @ObservationIgnored private let migration = ToolbarLayoutMigration()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loadedCustoms = Self.loadCustomActions(from: defaults)
        self.customActions = loadedCustoms
        self.reducer = Self.makeReducer(customActions: loadedCustoms)

        // Prefer the v2 layout; fall back to migrating a v1 arrangement; else a
        // first-launch default (everything shown in canonical order).
        let savedOrder: [ToolbarItemID]
        let savedEnabled: [ToolbarItemID]?
        if let v2Order = defaults.array(forKey: Self.orderDefaultsKey) as? [String] {
            savedOrder = v2Order.compactMap(ToolbarItemID.init(storageKey:))
            savedEnabled = (defaults.array(forKey: Self.enabledDefaultsKey) as? [String])?
                .compactMap(ToolbarItemID.init(storageKey:))
        } else if let v1Order = defaults.array(forKey: Self.legacyOrderDefaultsKey) as? [Int] {
            savedOrder = migration.migratedOrder(legacy: v1Order)
            savedEnabled = migration.migratedEnabled(
                legacy: defaults.array(forKey: Self.legacyEnabledDefaultsKey) as? [Int]
            )
        } else {
            savedOrder = []
            savedEnabled = nil
        }

        let layout = reducer.load(savedOrder: savedOrder, savedEnabled: savedEnabled)
        self.displayOrder = layout.order
        self.enabledSet = layout.enabled
        // Persist the normalized (and possibly migrated) layout so the migration
        // path runs at most once.
        persist()
    }

    // MARK: - Resolved items for the UI

    /// Every configurable item in display order (regardless of shown/hidden),
    /// resolved to its built-in action or custom action. This is what the
    /// settings editor lists.
    public var displayItems: [ResolvedToolbarItem] {
        displayOrder.compactMap(resolve)
    }

    /// The shown items in display order — exactly what the toolbar's configurable
    /// region renders, after the pinned modifier/zoom buttons.
    public var enabledItems: [ResolvedToolbarItem] {
        displayOrder.filter { enabledSet.contains($0) }.compactMap(resolve)
    }

    /// Whether `id` is currently shown on the bar.
    public func isEnabled(_ id: ToolbarItemID) -> Bool {
        enabledSet.contains(id)
    }

    // MARK: - Mutations

    /// Show or hide the item identified by `id`.
    public func setEnabled(_ id: ToolbarItemID, _ isEnabled: Bool) {
        apply(reducer.setEnabled(id, isEnabled, in: currentLayout))
        persistAndNotify()
    }

    /// Reorder the configurable items. `offsets`/`destination` are indices into
    /// ``displayOrder`` (the SwiftUI `onMove` contract).
    public func moveItems(from offsets: IndexSet, to destination: Int) {
        apply(reducer.move(from: offsets, to: destination, in: currentLayout))
        persistAndNotify()
    }

    /// Append a new custom action, shown at the end of the configurable region.
    public func addCustomAction(_ action: CustomToolbarAction) {
        customActions.append(action)
        reducer = Self.makeReducer(customActions: customActions)
        apply(reducer.load(
            savedOrder: displayOrder,
            savedEnabled: Array(enabledSet) + [action.itemID]
        ))
        persistAndNotify()
    }

    /// Replace an existing custom action in place (matched by ``CustomToolbarAction/id``).
    /// Its position and shown/hidden state are preserved.
    public func updateCustomAction(_ action: CustomToolbarAction) {
        guard let index = customActions.firstIndex(where: { $0.id == action.id }) else { return }
        customActions[index] = action
        reducer = Self.makeReducer(customActions: customActions)
        persistAndNotify()
    }

    /// Remove a custom action by id. It drops from the order and shown set.
    public func removeCustomAction(id: UUID) {
        guard customActions.contains(where: { $0.id == id }) else { return }
        customActions.removeAll { $0.id == id }
        reducer = Self.makeReducer(customActions: customActions)
        apply(reducer.load(savedOrder: displayOrder, savedEnabled: Array(enabledSet)))
        persistAndNotify()
    }

    /// Restore the default arrangement (canonical order, every item shown).
    /// Custom actions are kept (appended after the built-ins), not deleted.
    public func resetToDefaults() {
        apply(reducer.defaultLayout())
        persistAndNotify()
    }

    // MARK: - Internals

    private func resolve(_ id: ToolbarItemID) -> ResolvedToolbarItem? {
        switch id {
        case let .builtin(rawValue):
            return TerminalInputAccessoryAction(rawValue: rawValue).map(ResolvedToolbarItem.builtin)
        case let .custom(uuid):
            return customActions.first { $0.id == uuid }.map(ResolvedToolbarItem.custom)
        }
    }

    private var currentLayout: TerminalAccessoryLayoutReducer<ToolbarItemID>.Layout {
        .init(order: displayOrder, enabled: enabledSet)
    }

    private func apply(_ layout: TerminalAccessoryLayoutReducer<ToolbarItemID>.Layout) {
        displayOrder = layout.order
        enabledSet = layout.enabled
    }

    private static func makeReducer(
        customActions: [CustomToolbarAction]
    ) -> TerminalAccessoryLayoutReducer<ToolbarItemID> {
        let builtin = TerminalInputAccessoryAction.configurableActions.map(\.itemID)
        let custom = customActions.map(\.itemID)
        // The redesigned bar's curated built-in arrangement first, then customs,
        // so a fresh install shows the new default layout.
        let defaultOrder = TerminalInputAccessoryAction.defaultConfigurableOrder.map(\.itemID) + custom
        return TerminalAccessoryLayoutReducer(configurable: builtin + custom, defaultOrder: defaultOrder)
    }

    private static func loadCustomActions(from defaults: UserDefaults) -> [CustomToolbarAction] {
        guard let data = defaults.data(forKey: Self.customDefaultsKey),
              let decoded = try? JSONDecoder().decode([CustomToolbarAction].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist() {
        defaults.set(displayOrder.map(\.storageKey), forKey: Self.orderDefaultsKey)
        defaults.set(
            displayOrder.filter { enabledSet.contains($0) }.map(\.storageKey),
            forKey: Self.enabledDefaultsKey
        )
        if let data = try? JSONEncoder().encode(customActions) {
            defaults.set(data, forKey: Self.customDefaultsKey)
        }
    }

    private func persistAndNotify() {
        persist()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
