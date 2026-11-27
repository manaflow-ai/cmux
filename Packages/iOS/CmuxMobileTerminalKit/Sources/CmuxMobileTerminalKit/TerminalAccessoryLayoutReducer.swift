public import Foundation

/// Pure, `Sendable` reducer for the terminal input-accessory bar's configurable
/// region: which insertable shortcuts are shown and in what order.
///
/// The terminal accessory bar has two regions. The leading region (modifier and
/// zoom controls) is structural and pinned, so it is never modeled here. The
/// trailing region is the user-configurable list of insertable shortcuts (Esc,
/// Tab, arrows, `$`, `/`, `@`, `^C`, the agent launchers, …). This reducer owns
/// the *logic* for that trailing region — load/merge/forward-compat, enable
/// toggling, reordering, and reset — as pure transformations over the raw `Int`
/// identifiers of those actions, so it stays decoupled from the UIKit-gated
/// `TerminalInputAccessoryAction` enum and is testable from `swift test`.
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
/// var layout = reducer.load(savedOrder: [2, 0], savedEnabled: nil)
/// // layout.order == [2, 0, 1, 3] (saved first, then forward-compat append)
/// // layout.enabled == [0, 1, 2, 3] (nil enabled ⇒ everything on first launch)
/// layout = reducer.setEnabled(1, false, in: layout)
/// // layout.visibleOrder == [2, 0, 3]
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
        /// Every configurable identifier in the user's arranged order.
        public let order: [ID]
        /// The subset of ``order`` currently shown on the bar.
        public let enabled: Set<ID>

        /// Creates a layout snapshot.
        ///
        /// - Parameters:
        ///   - order: The configurable identifiers in display order.
        ///   - enabled: The identifiers currently shown.
        public init(order: [ID], enabled: Set<ID>) {
            self.order = order
            self.enabled = enabled
        }

        /// The enabled identifiers in display order — exactly what the toolbar's
        /// configurable region renders, after the pinned leading buttons.
        public var visibleOrder: [ID] {
            order.filter { enabled.contains($0) }
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
        var order = savedOrder.filter { configurableSet.contains($0) }
        var seen = Set(order)
        for identifier in defaultOrder where !seen.contains(identifier) {
            order.append(identifier)
            seen.insert(identifier)
        }

        let enabled: Set<ID>
        if let savedEnabled {
            enabled = Set(savedEnabled.filter { configurableSet.contains($0) })
        } else {
            enabled = configurableSet
        }
        return Layout(order: order, enabled: enabled)
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
        return Layout(order: layout.order, enabled: enabled)
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
        return Layout(order: order, enabled: layout.enabled)
    }

    /// The default layout: ``defaultOrder`` with every shortcut shown.
    public func defaultLayout() -> Layout {
        Layout(order: defaultOrder, enabled: configurableSet)
    }
}
