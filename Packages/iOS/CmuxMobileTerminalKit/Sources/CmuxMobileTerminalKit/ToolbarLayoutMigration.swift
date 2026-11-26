/// Forward-migration of the terminal accessory bar's persisted layout across the
/// schema generations keyed by ``ToolbarItemID``.
///
/// Two upgrade boundaries are handled:
///
/// - **v1 → v2 relabel.** The v1 bar stored parallel `[Int]` arrays of built-in
///   `rawValue`s and had no custom actions, so migration is a pure relabel: every
///   stored `Int` becomes a ``ToolbarItemID/builtin(_:)``. This preserves the
///   user's existing order and shown/hidden set exactly.
/// - **v1/v2 → v3 widening.** v1 and v2 modeled only the *trailing* shortcut
///   region as configurable; the leading modifier keys (⌃ ⌥ ⌘), the zoom
///   controls, and paste were structurally pinned and therefore absent from the
///   persisted order/enabled sets. v3 folds those built-ins into the same
///   configurable region. A naive load would treat the now-configurable ids as
///   "user hid them" and drop them from the bar, so
///   ``widenedToV3(order:enabled:forcedLeading:forcedTrailing:)`` deliberately
///   force-enables them and inserts them at their old fixed positions (leading
///   ids prepended, trailing ids appended) so an upgrading user's bar looks
///   unchanged.
///
/// The force-enable is intentionally confined to this upgrade boundary: once a
/// config is on the v3 schema its enabled set is authoritative, so hiding a
/// modifier persists. Callers detect "already on v3" by the presence of the v3
/// storage keys and skip this migration entirely.
public struct ToolbarLayoutMigration: Sendable {
    /// Creates a migration helper.
    public init() {}

    /// Maps a legacy order array of built-in `rawValue`s to unified identifiers,
    /// preserving order.
    /// - Parameter legacy: The persisted v1 `displayOrder` array.
    /// - Returns: The same sequence as ``ToolbarItemID/builtin(_:)`` values.
    public func migratedOrder(legacy: [Int]) -> [ToolbarItemID] {
        legacy.map { .builtin($0) }
    }

    /// Maps a legacy enabled array of built-in `rawValue`s to unified
    /// identifiers, preserving the distinction between "user hid everything"
    /// (empty array) and "first launch" (`nil`).
    /// - Parameter legacy: The persisted v1 `enabled` array, or `nil`.
    /// - Returns: The same set as ``ToolbarItemID/builtin(_:)`` values, or `nil`.
    public func migratedEnabled(legacy: [Int]?) -> [ToolbarItemID]? {
        legacy.map { $0.map { .builtin($0) } }
    }

    /// The persisted order/enabled produced by widening a v1/v2 layout to v3.
    public struct WidenedLayout: Equatable, Sendable {
        /// The configurable identifiers in display order, with the newly-configurable
        /// built-ins inserted at their old fixed positions.
        public let order: [ToolbarItemID]
        /// The shown identifiers, with the newly-configurable built-ins force-enabled.
        /// Never `nil`: a v3 config always has an authoritative enabled set.
        public let enabled: [ToolbarItemID]

        /// Creates a widened layout.
        /// - Parameters:
        ///   - order: The configurable identifiers in display order.
        ///   - enabled: The shown identifiers.
        public init(order: [ToolbarItemID], enabled: [ToolbarItemID]) {
            self.order = order
            self.enabled = enabled
        }
    }

    /// Widens a v1/v2 layout to v3 by folding the previously-pinned built-ins into
    /// the configurable region: they are prepended/appended to the saved order at
    /// their old fixed positions and force-enabled, so the bar looks unchanged
    /// after the upgrade.
    ///
    /// The transform is pure and identifier-agnostic: callers pass the raw
    /// `rawValue`s of the built-ins that were pinned leading/trailing (the
    /// `TerminalInputAccessoryAction` enum lives one layer up and is not visible
    /// here). Any forced id already present in `order` keeps its saved position
    /// rather than being duplicated, so a user who somehow already had one stays
    /// stable.
    ///
    /// - Parameters:
    ///   - order: The saved v1/v2 order (already relabeled to ``ToolbarItemID``),
    ///     covering only the previously-configurable shortcuts.
    ///   - enabled: The saved v1/v2 enabled set, or `nil` if the saved config
    ///     never recorded one. `nil` is treated as "all saved ids shown".
    ///   - forcedLeading: `rawValue`s of the built-ins that were pinned at the
    ///     front, in left-to-right order.
    ///   - forcedTrailing: `rawValue`s of the built-ins that were pinned at the
    ///     end, in left-to-right order.
    /// - Returns: The v3 order and force-enabled set.
    public func widenedToV3(
        order: [ToolbarItemID],
        enabled: [ToolbarItemID]?,
        forcedLeading: [Int],
        forcedTrailing: [Int]
    ) -> WidenedLayout {
        let leading = forcedLeading.map(ToolbarItemID.builtin)
        let trailing = forcedTrailing.map(ToolbarItemID.builtin)
        let savedSet = Set(order)

        // Insert each forced id only if the saved order didn't already carry it,
        // preserving the saved arrangement for everything else.
        let newLeading = leading.filter { !savedSet.contains($0) }
        let newLeadingSet = Set(newLeading)
        let newTrailing = trailing.filter { !savedSet.contains($0) && !newLeadingSet.contains($0) }
        let widenedOrder = newLeading + order + newTrailing

        // Force the forced ids on; keep the saved shown set for everything else.
        // A nil saved enabled means "everything that was in the saved order".
        let savedEnabled = enabled ?? order
        var enabledSet = savedEnabled
        var seen = Set(savedEnabled)
        for id in newLeading + newTrailing where seen.insert(id).inserted {
            enabledSet.append(id)
        }
        return WidenedLayout(order: widenedOrder, enabled: enabledSet)
    }

    /// Folds a built-in that became user-configurable *after* the v3 schema
    /// shipped into an existing v3 layout.
    ///
    /// A persisted v3 layout that predates `id` becoming configurable has no
    /// record of it, so a naive load would treat it as "the user hid this" and
    /// leave it off the bar. This detects that exact case — `id` absent from the
    /// saved `order` — and folds `id` in: it is inserted immediately after the
    /// first present entry of `anchors` (falling back to the front when none is
    /// present) and force-shown, matching a fresh install.
    ///
    /// The fold is intentionally one-shot: it keys off `id`'s *absence from the
    /// order*, not its enabled state. Once folded in, `id` lives in the persisted
    /// order on every later launch, so this returns `nil` (no-op) and the user's
    /// own shown/hidden choice for `id` becomes authoritative — a user who hides
    /// it keeps it hidden.
    ///
    /// - Parameters:
    ///   - id: The newly-configurable identifier to fold in.
    ///   - anchors: Candidate predecessors, in priority order; `id` is inserted
    ///     right after the first one present in `order`.
    ///   - order: The saved v3 order.
    ///   - enabled: The saved v3 enabled set.
    /// - Returns: The folded order/enabled, or `nil` when `id` is already present
    ///   in `order` (no migration needed).
    public func foldingNewlyConfigurable(
        _ id: ToolbarItemID,
        after anchors: [ToolbarItemID],
        order: [ToolbarItemID],
        enabled: [ToolbarItemID]
    ) -> WidenedLayout? {
        guard !order.contains(id) else { return nil }
        var newOrder = order
        let insertIndex: Int
        if let anchor = anchors.first(where: { newOrder.contains($0) }),
           let anchorIndex = newOrder.firstIndex(of: anchor) {
            insertIndex = newOrder.index(after: anchorIndex)
        } else {
            insertIndex = 0
        }
        newOrder.insert(id, at: insertIndex)
        var newEnabled = enabled
        if !newEnabled.contains(id) { newEnabled.append(id) }
        return WidenedLayout(order: newOrder, enabled: newEnabled)
    }
}
