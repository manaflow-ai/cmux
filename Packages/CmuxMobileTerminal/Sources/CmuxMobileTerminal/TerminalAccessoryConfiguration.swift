import CmuxMobileTerminalKit
import Foundation
import Observation

/// User-editable configuration of the terminal input-accessory bar: which
/// buttons appear, in what order, and any user-defined ``CustomToolbarAction``s.
///
/// Every button on the bar is configurable: the modifier keys (⌃ ⌥ ⌘ ⇧), the zoom
/// controls, paste, the shipped insertable shortcuts (Esc, Tab, arrows, the agent
/// launchers, …), and any custom actions, all ordered and toggled together and
/// keyed by ``ToolbarItemID``. (The composer toggle and the trailing "customize"
/// control are the only structural exceptions; the composer is pinned outside the
/// scroll view and the customize control is a fixed affordance, not an action.)
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

    // v3 schema, keyed by ``ToolbarItemID`` storage keys + JSON custom actions.
    // v3 widened the configurable region to include the modifier/zoom/paste
    // built-ins that v1/v2 pinned, so its enabled set is authoritative (it knows
    // those built-ins are hideable); presence of these keys means "skip the
    // force-enable widening migration".
    private static let orderDefaultsKey = "cmux.terminal.toolbar.order.v3"
    private static let enabledDefaultsKey = "cmux.terminal.toolbar.enabled.v3"
    // Custom actions are schema-stable across v2 and v3, so the v2 key is reused.
    private static let customDefaultsKey = "cmux.terminal.toolbar.custom.v2"
    // v2 schema (ToolbarItemID storage keys, configurable region = trailing
    // shortcuts only), read once to forward-migrate an upgrading user.
    private static let legacyV2OrderDefaultsKey = "cmux.terminal.toolbar.order.v2"
    private static let legacyV2EnabledDefaultsKey = "cmux.terminal.toolbar.enabled.v2"
    // v1 schema (parallel [Int] arrays of built-in rawValues), read once to
    // forward-migrate an upgrading user's existing arrangement.
    private static let legacyV1OrderDefaultsKey = "cmux.terminal.accessory.displayOrder.v1"
    private static let legacyV1EnabledDefaultsKey = "cmux.terminal.accessory.enabled.v1"

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

    /// Creates a configuration backed by `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` store to read and persist the
    ///   layout from. Defaults to `.standard` for the live ``shared`` instance;
    ///   tests inject a suite-scoped store so they exercise migration and
    ///   reorder/hide behavior without touching the user's real settings.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loadedCustoms = Self.loadCustomActions(from: defaults)
        self.customActions = loadedCustoms
        self.reducer = Self.makeReducer(customActions: loadedCustoms)

        // Resolve the persisted layout across schema generations:
        //   v3 present  → authoritative; load as-is (modifiers can stay hidden).
        //   else v2 present → widen to v3 (force-enable the now-configurable
        //                     modifier/zoom/paste built-ins at their old spots).
        //   else v1 present → relabel v1→ids, then widen to v3 the same way.
        //   else fresh install → empty saved + nil enabled ⇒ default layout,
        //                        which already includes modifiers/zoom/paste.
        let savedOrder: [ToolbarItemID]
        let savedEnabled: [ToolbarItemID]?
        if let v3Order = defaults.array(forKey: Self.orderDefaultsKey) as? [String] {
            let order = v3Order.compactMap(ToolbarItemID.init(storageKey:))
            let enabled = (defaults.array(forKey: Self.enabledDefaultsKey) as? [String])?
                .compactMap(ToolbarItemID.init(storageKey:))
            // ⇧ became user-configurable after the v3 schema shipped, so a layout
            // persisted under the v3 keys has no record of it and a naive load
            // would leave it hidden. Fold ⇧ in next to the other modifiers and
            // show it — once, keyed off ⇧'s absence from the saved order — so an
            // existing install surfaces it like a fresh one. Once ⇧ is persisted
            // into the order it is present on every later launch, so the fold
            // becomes a no-op and a user who then hides ⇧ keeps it hidden.
            if let folded = migration.foldingNewlyConfigurable(
                TerminalInputAccessoryAction.shift.itemID,
                after: [
                    TerminalInputAccessoryAction.command.itemID,
                    TerminalInputAccessoryAction.alternate.itemID,
                    TerminalInputAccessoryAction.control.itemID,
                ],
                order: order,
                enabled: enabled ?? order
            ) {
                savedOrder = folded.order
                savedEnabled = folded.enabled
            } else {
                savedOrder = order
                savedEnabled = enabled
            }
        } else if let v2Order = defaults.array(forKey: Self.legacyV2OrderDefaultsKey) as? [String] {
            let widened = migration.widenedToV3(
                order: v2Order.compactMap(ToolbarItemID.init(storageKey:)),
                enabled: (defaults.array(forKey: Self.legacyV2EnabledDefaultsKey) as? [String])?
                    .compactMap(ToolbarItemID.init(storageKey:)),
                forcedLeading: Self.forcedLeadingRawValues,
                forcedTrailing: Self.forcedTrailingRawValues
            )
            savedOrder = widened.order
            savedEnabled = widened.enabled
        } else if let v1Order = defaults.array(forKey: Self.legacyV1OrderDefaultsKey) as? [Int] {
            let widened = migration.widenedToV3(
                order: migration.migratedOrder(legacy: v1Order),
                enabled: migration.migratedEnabled(
                    legacy: defaults.array(forKey: Self.legacyV1EnabledDefaultsKey) as? [Int]
                ),
                forcedLeading: Self.forcedLeadingRawValues,
                forcedTrailing: Self.forcedTrailingRawValues
            )
            savedOrder = widened.order
            savedEnabled = widened.enabled
        } else {
            savedOrder = []
            savedEnabled = nil
        }

        let layout = reducer.load(savedOrder: savedOrder, savedEnabled: savedEnabled)
        self.displayOrder = layout.order
        self.enabledSet = layout.enabled
        // Persist the normalized (and possibly migrated) layout under the v3 keys
        // so the migration path runs at most once.
        persist()
    }

    /// `rawValue`s of the built-ins that v1/v2 pinned at the front of the bar,
    /// passed to the v3 widening migration so they are force-enabled and inserted
    /// at the front for an upgrading user.
    private static let forcedLeadingRawValues = TerminalInputAccessoryAction.defaultLeadingActions.map(\.rawValue)
    /// `rawValue`s of the built-ins that v1/v2 pinned at the end of the bar (zoom).
    private static let forcedTrailingRawValues = TerminalInputAccessoryAction.defaultTrailingActions.map(\.rawValue)

    // MARK: - Resolved items for the UI

    /// Every configurable item in display order (regardless of shown/hidden),
    /// resolved to its built-in action or custom action. This is what the
    /// settings editor lists.
    public var displayItems: [ResolvedToolbarItem] {
        displayOrder.compactMap(resolve)
    }

    /// The shown items in display order — exactly what the toolbar renders, ahead
    /// of the fixed trailing "customize" control. ``TerminalInputTextView`` skips
    /// the ⌘ item when the session is not driving a Mac remote.
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
