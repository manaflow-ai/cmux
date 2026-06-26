import CmuxMobileTerminalKit
import Foundation
import Observation

/// User-editable configuration of the terminal input-accessory bar: which
/// buttons appear, which row they occupy, in what order, and any user-defined
/// ``CustomToolbarAction``s.
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

    /// Minimum number of configurable toolbar rows.
    public static let minimumRowCount = 1
    /// Maximum number of configurable toolbar rows.
    public static let maximumRowCount = 3

    // v4 schema, keyed by rows of ``ToolbarItemID`` storage keys + JSON custom
    // actions. Empty rows are persisted so an explicit row count survives.
    private static let rowsDefaultsKey = "cmux.terminal.toolbar.rows.v4"
    private static let enabledDefaultsKey = "cmux.terminal.toolbar.enabled.v4"
    // v3 schema, keyed by ``ToolbarItemID`` storage keys + JSON custom actions.
    // v3 widened the configurable region to include the modifier/zoom/paste
    // built-ins that v1/v2 pinned, so its enabled set is authoritative (it knows
    // those built-ins are hideable); presence of these keys means "skip the
    // force-enable widening migration".
    private static let legacyV3OrderDefaultsKey = "cmux.terminal.toolbar.order.v3"
    private static let legacyV3EnabledDefaultsKey = "cmux.terminal.toolbar.enabled.v3"
    // Custom actions are schema-stable across v2-v4, so the v2 key is reused.
    private static let customDefaultsKey = "cmux.terminal.toolbar.custom.v2"
    // v2 schema (ToolbarItemID storage keys, configurable region = trailing
    // shortcuts only), read once to forward-migrate an upgrading user.
    private static let legacyV2OrderDefaultsKey = "cmux.terminal.toolbar.order.v2"
    private static let legacyV2EnabledDefaultsKey = "cmux.terminal.toolbar.enabled.v2"
    // v1 schema (parallel [Int] arrays of built-in rawValues), read once to
    // forward-migrate an upgrading user's existing arrangement.
    private static let legacyV1OrderDefaultsKey = "cmux.terminal.accessory.displayOrder.v1"
    private static let legacyV1EnabledDefaultsKey = "cmux.terminal.accessory.enabled.v1"

    /// The configurable items arranged into the toolbar rows the user configured,
    /// as unified identifiers (built-ins and custom actions together).
    public private(set) var displayRows: [[ToolbarItemID]]

    /// The configurable items in row-major order.
    public var displayOrder: [ToolbarItemID] {
        displayRows.flatMap { $0 }
    }

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
        let savedRows: [[ToolbarItemID]]?
        var savedOrder: [ToolbarItemID] = []
        let savedEnabled: [ToolbarItemID]?
        let rowCount: Int
        if let v4Rows = Self.loadRows(from: defaults) {
            savedRows = v4Rows
            savedEnabled = (defaults.array(forKey: Self.enabledDefaultsKey) as? [String])?
                .compactMap(ToolbarItemID.init(storageKey:))
            rowCount = Self.clampedRowCount(v4Rows.count)
        } else if let v3Order = defaults.array(forKey: Self.legacyV3OrderDefaultsKey) as? [String] {
            savedRows = nil
            let order = v3Order.compactMap(ToolbarItemID.init(storageKey:))
            let enabled = (defaults.array(forKey: Self.legacyV3EnabledDefaultsKey) as? [String])?
                .compactMap(ToolbarItemID.init(storageKey:))
            // ⇧ and Return each became user-configurable after the v3 schema
            // shipped, so a layout persisted under the v3 keys has no record of
            // them and a naive load would leave them hidden. Fold each in next to
            // its neighbours and show it — once per id, keyed off that id's
            // absence from the saved order — so an existing install surfaces them
            // like a fresh one. Once an id is persisted into the order it is
            // present on every later launch, so the fold becomes a no-op and a
            // user who then hides it keeps it hidden.
            let folded = Self.foldNewlyConfigurableV3(order: order, enabled: enabled, migration: migration)
            savedOrder = folded.order
            savedEnabled = folded.enabled
            rowCount = Self.minimumRowCount
        } else if let v2Order = defaults.array(forKey: Self.legacyV2OrderDefaultsKey) as? [String] {
            savedRows = nil
            let widened = migration.widenedToV3(
                order: v2Order.compactMap(ToolbarItemID.init(storageKey:)),
                enabled: (defaults.array(forKey: Self.legacyV2EnabledDefaultsKey) as? [String])?
                    .compactMap(ToolbarItemID.init(storageKey:)),
                forcedLeading: Self.forcedLeadingRawValues,
                forcedTrailing: Self.forcedTrailingRawValues
            )
            // The widening force-enables the pinned modifiers/zoom but never the
            // post-v3 shortcuts; a v2 config predates Return, so fold it in too.
            let folded = Self.foldNewlyConfigurableV3(order: widened.order, enabled: widened.enabled, migration: migration)
            savedOrder = folded.order
            savedEnabled = folded.enabled
            rowCount = Self.minimumRowCount
        } else if let v1Order = defaults.array(forKey: Self.legacyV1OrderDefaultsKey) as? [Int] {
            savedRows = nil
            let widened = migration.widenedToV3(
                order: migration.migratedOrder(legacy: v1Order),
                enabled: migration.migratedEnabled(
                    legacy: defaults.array(forKey: Self.legacyV1EnabledDefaultsKey) as? [Int]
                ),
                forcedLeading: Self.forcedLeadingRawValues,
                forcedTrailing: Self.forcedTrailingRawValues
            )
            // Same as the v2 path: fold in the post-v3 shortcuts the widening
            // doesn't cover (Return), force-shown, exactly once.
            let folded = Self.foldNewlyConfigurableV3(order: widened.order, enabled: widened.enabled, migration: migration)
            savedOrder = folded.order
            savedEnabled = folded.enabled
            rowCount = Self.minimumRowCount
        } else {
            savedRows = nil
            savedEnabled = nil
            rowCount = Self.minimumRowCount
        }

        let layout = reducer.load(
            savedRows: savedRows,
            savedOrder: savedOrder,
            savedEnabled: savedEnabled,
            rowCount: rowCount
        )
        self.displayRows = layout.rows
        self.enabledSet = layout.enabled
        // Persist the normalized (and possibly migrated) layout under the v4 keys
        // so the migration path runs at most once.
        persist()
    }

    /// Folds the built-ins that became user-configurable *after* the v3 schema
    /// shipped (⇧, then Return) into a persisted v3 layout, each adjacent to its
    /// canonical neighbours and force-shown, exactly once per id. Returns the
    /// possibly-folded order and enabled set; `enabled` is passed through
    /// unchanged (including `nil`) when no fold applies, so a config already
    /// carrying both keeps its authoritative shown/hidden choices.
    private static func foldNewlyConfigurableV3(
        order: [ToolbarItemID],
        enabled: [ToolbarItemID]?,
        migration: ToolbarLayoutMigration
    ) -> (order: [ToolbarItemID], enabled: [ToolbarItemID]?) {
        var resolvedOrder = order
        var resolvedEnabled = enabled
        // Each entry is the newly-configurable id plus the predecessors to insert
        // it after (first present wins; front if none present), mirroring
        // `defaultConfigurableOrder`: ⇧ trails the other modifiers, Return trails
        // Esc (then Tab, then the modifiers).
        let folds: [(id: ToolbarItemID, anchors: [ToolbarItemID])] = [
            (TerminalInputAccessoryAction.shift.itemID, [
                TerminalInputAccessoryAction.command.itemID,
                TerminalInputAccessoryAction.alternate.itemID,
                TerminalInputAccessoryAction.control.itemID,
            ]),
            (TerminalInputAccessoryAction.returnKey.itemID, [
                TerminalInputAccessoryAction.escape.itemID,
                TerminalInputAccessoryAction.tab.itemID,
                TerminalInputAccessoryAction.command.itemID,
                TerminalInputAccessoryAction.alternate.itemID,
                TerminalInputAccessoryAction.control.itemID,
            ]),
        ]
        for fold in folds {
            if let widened = migration.foldingNewlyConfigurable(
                fold.id,
                after: fold.anchors,
                order: resolvedOrder,
                enabled: resolvedEnabled ?? resolvedOrder
            ) {
                resolvedOrder = widened.order
                resolvedEnabled = widened.enabled
            }
        }
        return (resolvedOrder, resolvedEnabled)
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

    /// Every configurable item arranged by toolbar row, regardless of
    /// shown/hidden state.
    public var displayItemRows: [[ResolvedToolbarItem]] {
        displayRows.map { row in row.compactMap(resolve) }
    }

    /// The shown items arranged by toolbar row — exactly what the toolbar renders,
    /// ahead of the fixed trailing "customize" control.
    public var enabledItemRows: [[ResolvedToolbarItem]] {
        displayRows.map { row in
            row.filter { enabledSet.contains($0) }.compactMap(resolve)
        }
    }

    /// The number of persisted toolbar rows.
    public var rowCount: Int {
        displayRows.count
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

    /// Reorder the configurable items within a specific toolbar row.
    public func moveItems(from offsets: IndexSet, to destination: Int, inRow rowIndex: Int) {
        apply(reducer.move(from: offsets, to: destination, inRow: rowIndex, in: currentLayout))
        persistAndNotify()
    }

    /// Move one configurable item to the end of another toolbar row.
    public func moveItem(_ id: ToolbarItemID, toRow rowIndex: Int) {
        apply(reducer.move(id, toRow: rowIndex, in: currentLayout))
        persistAndNotify()
    }

    /// Change the number of visible toolbar rows.
    public func setRowCount(_ rowCount: Int) {
        apply(reducer.setRowCount(Self.clampedRowCount(rowCount), in: currentLayout))
        persistAndNotify()
    }

    /// Reorder the configurable items using a complete desired order.
    ///
    /// Unknown identifiers are dropped and any omitted current/configurable ids
    /// are appended by the reducer load path, matching launch-time normalization.
    public func reorderItems(_ orderedIDs: [ToolbarItemID]) {
        apply(reducer.load(
            savedRows: Self.split(orderedIDs, matchingRowLengthsOf: displayRows),
            savedEnabled: Array(enabledSet),
            rowCount: rowCount
        ))
        persistAndNotify()
    }

    /// Append a new custom action, shown at the end of the configurable region.
    public func addCustomAction(_ action: CustomToolbarAction) {
        customActions.append(action)
        reducer = Self.makeReducer(customActions: customActions)
        apply(reducer.load(
            savedRows: displayRows,
            savedEnabled: Array(enabledSet) + [action.itemID],
            rowCount: rowCount
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
        apply(reducer.load(savedRows: displayRows, savedEnabled: Array(enabledSet), rowCount: rowCount))
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
        .init(rows: displayRows, enabled: enabledSet)
    }

    private func apply(_ layout: TerminalAccessoryLayoutReducer<ToolbarItemID>.Layout) {
        displayRows = layout.rows
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

    private static func loadRows(from defaults: UserDefaults) -> [[ToolbarItemID]]? {
        guard let stored = defaults.array(forKey: Self.rowsDefaultsKey) else { return nil }
        return stored.map { row in
            guard let storageKeys = row as? [String] else { return [] }
            return storageKeys.compactMap(ToolbarItemID.init(storageKey:))
        }
    }

    /// Clamp a requested toolbar row count to the supported range.
    public static func clampedRowCount(_ rowCount: Int) -> Int {
        min(max(rowCount, minimumRowCount), maximumRowCount)
    }

    private static func split(
        _ order: [ToolbarItemID],
        matchingRowLengthsOf rows: [[ToolbarItemID]]
    ) -> [[ToolbarItemID]] {
        guard !rows.isEmpty else { return [order] }
        var result: [[ToolbarItemID]] = []
        var cursor = order.startIndex
        for row in rows {
            let remaining = order.distance(from: cursor, to: order.endIndex)
            let end = order.index(cursor, offsetBy: min(row.count, remaining))
            result.append(Array(order[cursor..<end]))
            cursor = end
        }
        if cursor < order.endIndex {
            result[result.count - 1].append(contentsOf: order[cursor...])
        }
        return result
    }

    private func persist() {
        defaults.set(displayRows.map { row in row.map(\.storageKey) }, forKey: Self.rowsDefaultsKey)
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
