public import Foundation

/// Pure, `Sendable` reducer for the terminal input-accessory bar's configurable
/// region: which shortcuts are shown, which row they occupy, and their order.
///
/// The terminal accessory bar exposes every shortcut/modifier/paste/zoom action
/// as user-configurable. This reducer owns the logic for that region —
/// load/merge/forward-compat, enable toggling, row-count changes, reordering,
/// row assignment, and reset — as pure transformations over opaque identifiers,
/// so it stays decoupled from the UIKit-gated `TerminalInputAccessoryAction`
/// enum and is testable from `swift test`.
///
/// Identifiers are opaque, `Hashable` values supplied by the caller. The reducer
/// never invents identifiers: every value it returns is drawn from the
/// `configurable` set it is constructed with, which the caller derives from the
/// canonical built-in order plus any user-defined custom actions. The bar's
/// built-in shortcuts are keyed by their enum `rawValue` and custom actions by a
/// stable UUID; ``ToolbarItemID`` unifies both behind one identifier, so the
/// reducer is instantiated as `TerminalAccessoryLayoutReducer<ToolbarItemID>`.
///
/// ```swift
/// let reducer = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3])
/// var layout = reducer.load(savedRows: [[2, 0]], savedEnabled: nil, rowCount: 2)
/// // layout.rows == [[2, 0], [1, 3]] (saved first, then forward-compat append)
/// // layout.enabled == [0, 1, 2, 3] (nil enabled ⇒ everything on first launch)
/// layout = reducer.setEnabled(1, false, in: layout)
/// // layout.visibleRows == [[2, 0], [3]]
/// ```
public struct TerminalAccessoryLayoutReducer<ID: Hashable & Sendable>: Sendable {
    /// The configurable action identifiers in canonical order. This is the
    /// complete valid set of identifiers the reducer will ever surface; every
    /// value it returns is drawn from here.
    public let configurable: [ID]

    /// The identifiers in their default on-bar arrangement, used on a fresh
    /// install and by ``defaultLayout()``, and as the tail order for forward-compat
    /// appends in ``load(savedOrder:savedEnabled:)``.
    ///
    /// Always a permutation of ``configurable``: the init drops unknown ids and
    /// appends any configurable id the caller omitted, so a curated default
    /// arrangement can never make an action vanish from the bar.
    public let defaultOrder: [ID]

    private let configurableSet: Set<ID>

    /// Creates a reducer over the given configurable action identifiers.
    ///
    /// - Parameters:
    ///   - configurable: Every user-configurable action identifier, in canonical
    ///     order (built-ins in enum order, then custom actions in their stored
    ///     order). This is the valid identifier set.
    ///   - defaultOrder: The default on-bar arrangement of those identifiers. Pass
    ///     `nil` (the default) to arrange them in canonical order. Unknown ids are
    ///     dropped and any omitted configurable id is appended, so the resolved
    ///     ``defaultOrder`` is always a permutation of `configurable`.
    public init(configurable: [ID], defaultOrder: [ID]? = nil) {
        let configurableSet = Set(configurable)
        self.configurable = configurable
        self.configurableSet = configurableSet

        var seen = Set<ID>()
        var resolved: [ID] = []
        for identifier in defaultOrder ?? configurable
        where configurableSet.contains(identifier) && seen.insert(identifier).inserted {
            resolved.append(identifier)
        }
        for identifier in configurable where seen.insert(identifier).inserted {
            resolved.append(identifier)
        }
        self.defaultOrder = resolved
    }

    /// An immutable snapshot of the configurable region's state.
    public struct Layout: Equatable, Sendable {
        /// Every configurable identifier in the user's arranged rows.
        ///
        /// Each identifier appears at most once. Empty rows are preserved so the
        /// user's configured row count survives even when a row has no actions.
        public let rows: [[ID]]
        /// The subset of ``order`` currently shown on the bar.
        public let enabled: Set<ID>

        /// Creates a layout snapshot.
        ///
        /// - Parameters:
        ///   - order: The configurable identifiers in display order.
        ///   - enabled: The identifiers currently shown.
        public init(order: [ID], enabled: Set<ID>) {
            self.rows = [order]
            self.enabled = enabled
        }

        /// Creates a row-aware layout snapshot.
        ///
        /// - Parameters:
        ///   - rows: The configurable identifiers arranged into toolbar rows.
        ///   - enabled: The identifiers currently shown.
        public init(rows: [[ID]], enabled: Set<ID>) {
            self.rows = rows.isEmpty ? [[]] : rows
            self.enabled = enabled
        }

        /// Every configurable identifier in row-major display order.
        public var order: [ID] {
            rows.flatMap { $0 }
        }

        /// The enabled identifiers in row-major display order.
        public var visibleOrder: [ID] {
            visibleRows.flatMap { $0 }
        }

        /// The enabled identifiers arranged by toolbar row.
        public var visibleRows: [[ID]] {
            rows.map { row in row.filter { enabled.contains($0) } }
        }
    }

    /// Builds a layout from persisted values, dropping unknown identifiers and
    /// appending any configurable action not yet persisted (forward-compat when
    /// the enum grows between builds).
    ///
    /// - Parameters:
    ///   - savedOrder: The persisted order (raw identifiers), or an empty array
    ///     when nothing was persisted.
    ///   - savedEnabled: The persisted enabled set (raw identifiers), or `nil`
    ///     on first launch. `nil` means "show everything"; an empty array means
    ///     the user hid every shortcut.
    /// - Returns: A normalized ``Layout`` containing exactly the configurable
    ///   identifiers.
    public func load(savedOrder: [ID], savedEnabled: [ID]?) -> Layout {
        load(savedRows: [savedOrder], savedEnabled: savedEnabled, rowCount: 1)
    }

    /// Builds a row-aware layout from persisted values, dropping unknown
    /// identifiers, de-duplicating across rows, preserving empty rows, and
    /// appending any configurable action not yet persisted.
    ///
    /// Forward-compatible identifiers are appended to the last row so an existing
    /// custom row arrangement remains stable while still surfacing new actions.
    /// If `rowCount` is smaller than the saved row count, overflow rows are merged
    /// into the last retained row. If it is larger, empty rows are appended.
    ///
    /// - Parameters:
    ///   - savedRows: The persisted row arrangement.
    ///   - savedEnabled: The persisted enabled set, or `nil` on first launch.
    ///     `nil` means "show everything"; an empty array means the user hid every
    ///     shortcut.
    ///   - rowCount: The requested number of toolbar rows. Values below 1 are
    ///     clamped to 1.
    /// - Returns: A normalized ``Layout`` containing exactly the configurable
    ///   identifiers.
    public func load(savedRows: [[ID]], savedEnabled: [ID]?, rowCount: Int) -> Layout {
        let desiredRowCount = max(1, rowCount)
        let persistedRows = savedRows.isEmpty ? [defaultOrder] : savedRows
        var rows = Array(repeating: [ID](), count: desiredRowCount)
        var seen = Set<ID>()
        for (sourceIndex, sourceRow) in persistedRows.enumerated() {
            let rowIndex = min(sourceIndex, desiredRowCount - 1)
            for identifier in sourceRow
            where configurableSet.contains(identifier) && seen.insert(identifier).inserted {
                rows[rowIndex].append(identifier)
            }
        }

        for identifier in defaultOrder where seen.insert(identifier).inserted {
            rows[desiredRowCount - 1].append(identifier)
        }

        let enabled: Set<ID>
        if let savedEnabled {
            enabled = Set(savedEnabled.filter { configurableSet.contains($0) })
        } else {
            enabled = configurableSet
        }
        return Layout(rows: rows, enabled: enabled)
    }

    /// Builds a row-aware layout from persisted rows, using `defaultOrder` as the
    /// fresh-install arrangement when no rows were saved.
    ///
    /// - Parameters:
    ///   - savedRows: The persisted row arrangement, or `nil` when not present.
    ///   - savedOrder: The legacy flat saved order to migrate when `savedRows` is
    ///     absent.
    ///   - savedEnabled: The persisted enabled set, or `nil` on first launch.
    ///   - rowCount: The requested number of toolbar rows.
    /// - Returns: A normalized ``Layout`` containing exactly the configurable
    ///   identifiers.
    public func load(
        savedRows: [[ID]]?,
        savedOrder: [ID],
        savedEnabled: [ID]?,
        rowCount: Int
    ) -> Layout {
        if let savedRows {
            return load(savedRows: savedRows, savedEnabled: savedEnabled, rowCount: rowCount)
        }
        return load(savedRows: savedOrder.isEmpty ? [defaultOrder] : [savedOrder], savedEnabled: savedEnabled, rowCount: rowCount)
    }

    /// Returns `layout` with `identifier` shown or hidden. A no-op for
    /// identifiers outside ``configurable``.
    ///
    /// - Parameters:
    ///   - identifier: The action identifier to toggle.
    ///   - isEnabled: `true` to show, `false` to hide.
    ///   - layout: The current layout.
    /// - Returns: The updated layout.
    public func setEnabled(_ identifier: ID, _ isEnabled: Bool, in layout: Layout) -> Layout {
        guard configurableSet.contains(identifier) else { return layout }
        var enabled = layout.enabled
        if isEnabled { enabled.insert(identifier) } else { enabled.remove(identifier) }
        return Layout(rows: layout.rows, enabled: enabled)
    }

    /// Returns `layout` with the configurable actions reordered.
    ///
    /// `offsets`/`destination` follow the SwiftUI `onMove` contract: indices into
    /// ``Layout/order``.
    ///
    /// - Parameters:
    ///   - offsets: The indices being moved.
    ///   - destination: The insertion index.
    ///   - layout: The current layout.
    /// - Returns: The updated layout.
    public func move(from offsets: IndexSet, to destination: Int, in layout: Layout) -> Layout {
        var order = layout.order
        // Foundation-only equivalent of SwiftUI's `Array.move(fromOffsets:toOffset:)`
        // (the `onMove` contract): pull the moved elements out preserving their
        // relative order, then reinsert at `destination` adjusted for any removed
        // elements that sat before it.
        let movedIndices = offsets.sorted()
        let moved = movedIndices.map { order[$0] }
        for index in movedIndices.reversed() {
            order.remove(at: index)
        }
        let insertionIndex = destination - movedIndices.filter { $0 < destination }.count
        order.insert(contentsOf: moved, at: max(0, min(insertionIndex, order.count)))
        return Layout(rows: split(order, matchingRowLengthsOf: layout.rows), enabled: layout.enabled)
    }

    /// Returns `layout` with a scoped set of identifiers reordered inside their current rows.
    ///
    /// Use this when a settings surface shows only part of the toolbar. Identifiers
    /// outside `scopedIDs` keep their exact row positions, and scoped identifiers are
    /// reordered only among the scoped slots in the row they already occupy. Moving
    /// an item between rows must go through ``move(_:toRow:in:)``.
    ///
    /// - Parameters:
    ///   - orderedIDs: The desired row-major order for the scoped identifiers.
    ///   - scopedIDs: The identifiers the caller's current surface is allowed to move.
    ///   - layout: The current layout.
    /// - Returns: The updated layout.
    public func reorder(_ orderedIDs: [ID], limitedTo scopedIDs: Set<ID>, in layout: Layout) -> Layout {
        let validScopedIDs = scopedIDs.intersection(configurableSet)
        guard !validScopedIDs.isEmpty else { return layout }

        var seen = Set<ID>()
        let desiredScopedOrder = orderedIDs.filter { identifier in
            configurableSet.contains(identifier)
                && validScopedIDs.contains(identifier)
                && seen.insert(identifier).inserted
        }
        guard !desiredScopedOrder.isEmpty else { return layout }

        var rows = layout.rows
        for rowIndex in rows.indices {
            let row = rows[rowIndex]
            let rowScopedIDs = Set(row.filter { validScopedIDs.contains($0) })
            guard !rowScopedIDs.isEmpty else { continue }

            var rowSeen = Set<ID>()
            var rowScopedOrder = desiredScopedOrder.filter { identifier in
                rowScopedIDs.contains(identifier) && rowSeen.insert(identifier).inserted
            }
            for identifier in row where rowScopedIDs.contains(identifier) && rowSeen.insert(identifier).inserted {
                rowScopedOrder.append(identifier)
            }

            var iterator = rowScopedOrder.makeIterator()
            rows[rowIndex] = row.map { identifier in
                guard rowScopedIDs.contains(identifier) else { return identifier }
                return iterator.next() ?? identifier
            }
        }
        return Layout(rows: rows, enabled: layout.enabled)
    }

    /// Returns `layout` with items moved within one toolbar row.
    ///
    /// `offsets`/`destination` follow the SwiftUI `onMove` contract: indices into
    /// the selected row.
    ///
    /// - Parameters:
    ///   - offsets: The row-local indices being moved.
    ///   - destination: The row-local insertion index.
    ///   - rowIndex: The row to reorder.
    ///   - layout: The current layout.
    /// - Returns: The updated layout.
    public func move(from offsets: IndexSet, to destination: Int, inRow rowIndex: Int, in layout: Layout) -> Layout {
        guard layout.rows.indices.contains(rowIndex) else { return layout }
        var rows = layout.rows
        var row = rows[rowIndex]
        var validOffsets = IndexSet()
        for offset in offsets where row.indices.contains(offset) {
            validOffsets.insert(offset)
        }
        guard !validOffsets.isEmpty else { return layout }
        let movedIndices = validOffsets.sorted()
        let moved = movedIndices.map { row[$0] }
        for index in movedIndices.reversed() {
            row.remove(at: index)
        }
        let insertionIndex = destination - movedIndices.filter { $0 < destination }.count
        row.insert(contentsOf: moved, at: max(0, min(insertionIndex, row.count)))
        rows[rowIndex] = row
        return Layout(rows: rows, enabled: layout.enabled)
    }

    /// Returns `layout` with `identifier` moved to the end of another row.
    ///
    /// A no-op for unknown identifiers or invalid row indices.
    ///
    /// - Parameters:
    ///   - identifier: The action identifier to move.
    ///   - rowIndex: The destination row.
    ///   - layout: The current layout.
    /// - Returns: The updated layout.
    public func move(_ identifier: ID, toRow rowIndex: Int, in layout: Layout) -> Layout {
        guard configurableSet.contains(identifier), layout.rows.indices.contains(rowIndex) else { return layout }
        var rows = layout.rows.map { row in row.filter { $0 != identifier } }
        rows[rowIndex].append(identifier)
        return Layout(rows: rows, enabled: layout.enabled)
    }

    /// Returns `layout` with its toolbar row count changed.
    ///
    /// Reducing the count preserves every action by merging overflow rows into
    /// the last retained row. Increasing the count appends empty rows.
    ///
    /// Rows are numbered top-to-bottom: "Row 1"…"Row N" in the settings UI, and
    /// in the toolbar "Row 1" renders at the top down to "Row N" nearest the
    /// keyboard (the last row also carries the fixed HIDE/customize controls).
    /// Growth deliberately appends the new empty rows *after* the existing ones
    /// so each existing row keeps its number and position instead of being
    /// renumbered/shifted on every count change; the added rows start empty and
    /// the user fills them via the per-item "Move to Row" picker (`move(_:toRow:in:)`)
    /// and within-row drag. Prepending/bottom-anchoring instead would push the
    /// user's existing shortcuts to a higher-numbered row on every increase,
    /// contradicting the stable "Row 1…N" numbering. This is intentional and
    /// pinned by `TerminalAccessoryLayoutReducerTests`.
    ///
    /// - Parameters:
    ///   - rowCount: The requested row count. Values below 1 are clamped to 1.
    ///   - layout: The current layout.
    /// - Returns: The updated layout.
    public func setRowCount(_ rowCount: Int, in layout: Layout) -> Layout {
        let desiredRowCount = max(1, rowCount)
        var rows = layout.rows.isEmpty ? [[]] : layout.rows
        if rows.count > desiredRowCount {
            let keptPrefix = rows.prefix(desiredRowCount - 1)
            let mergedTail = rows.dropFirst(desiredRowCount - 1).flatMap { $0 }
            rows = Array(keptPrefix) + [mergedTail]
        } else if rows.count < desiredRowCount {
            // Append (not prepend) so existing rows keep their "Row 1…k" numbers;
            // see the doc comment above for why growth is intentionally top-anchored.
            rows.append(contentsOf: Array(repeating: [], count: desiredRowCount - rows.count))
        }
        return Layout(rows: rows, enabled: layout.enabled)
    }

    /// The default layout: ``defaultOrder`` in one row, with every shortcut shown.
    public func defaultLayout() -> Layout {
        Layout(order: defaultOrder, enabled: configurableSet)
    }

    private func split(_ order: [ID], matchingRowLengthsOf rows: [[ID]]) -> [[ID]] {
        guard !rows.isEmpty else { return [order] }
        var result: [[ID]] = []
        var cursor = order.startIndex
        for row in rows {
            let end = order.index(cursor, offsetBy: min(row.count, order.distance(from: cursor, to: order.endIndex)))
            result.append(Array(order[cursor..<end]))
            cursor = end
        }
        if cursor < order.endIndex {
            result[result.count - 1].append(contentsOf: order[cursor...])
        }
        return result
    }
}
