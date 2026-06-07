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
/// Identifiers are the `rawValue`s of the configurable actions. The reducer
/// never invents identifiers: every value it returns is drawn from the
/// `configurable` set it is constructed with, which the caller derives from the
/// canonical enum order.
///
/// ```swift
/// let reducer = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3])
/// var layout = reducer.load(savedOrder: [2, 0], savedEnabled: nil)
/// // layout.order == [2, 0, 1, 3] (saved first, then forward-compat append)
/// // layout.enabled == [0, 1, 2, 3] (nil enabled ⇒ everything on first launch)
/// layout = reducer.setEnabled(1, false, in: layout)
/// // layout.visibleOrder == [2, 0, 3]
/// ```
public struct TerminalAccessoryLayoutReducer: Sendable {
    /// The configurable action identifiers in canonical (enum) order. This is the
    /// complete set the reducer will ever surface and the default arrangement.
    public let configurable: [Int]

    private let configurableSet: Set<Int>

    /// Creates a reducer over the given configurable action identifiers.
    ///
    /// - Parameter configurable: The `rawValue`s of every user-configurable
    ///   action, in canonical (enum) order. Order matters: it is the default
    ///   arrangement and the tail order for forward-compat appends.
    public init(configurable: [Int]) {
        self.configurable = configurable
        self.configurableSet = Set(configurable)
    }

    /// An immutable snapshot of the configurable region's state.
    public struct Layout: Equatable, Sendable {
        /// Every configurable identifier in the user's arranged order.
        public let order: [Int]
        /// The subset of ``order`` currently shown on the bar.
        public let enabled: Set<Int>

        /// Creates a layout snapshot.
        ///
        /// - Parameters:
        ///   - order: The configurable identifiers in display order.
        ///   - enabled: The identifiers currently shown.
        public init(order: [Int], enabled: Set<Int>) {
            self.order = order
            self.enabled = enabled
        }

        /// The enabled identifiers in display order — exactly what the toolbar's
        /// configurable region renders, after the pinned leading buttons.
        public var visibleOrder: [Int] {
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
    public func load(savedOrder: [Int], savedEnabled: [Int]?) -> Layout {
        var order = savedOrder.filter { configurableSet.contains($0) }
        var seen = Set(order)
        for identifier in configurable where !seen.contains(identifier) {
            order.append(identifier)
            seen.insert(identifier)
        }

        let enabled: Set<Int>
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
    public func setEnabled(_ identifier: Int, _ isEnabled: Bool, in layout: Layout) -> Layout {
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

    /// The default layout: canonical order with every shortcut shown.
    public func defaultLayout() -> Layout {
        Layout(order: configurable, enabled: configurableSet)
    }
}
