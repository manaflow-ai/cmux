public import SwiftUI

/// Immutable snapshot of the command-palette result list as it should render.
///
/// The host (currently `ContentView`) computes one of these from its live
/// palette state and hands it to ``CommandPaletteCoordinator/scheduleCommandListUpdate(_:)``;
/// the coordinator coalesces updates and publishes the latest snapshot to the
/// paired UI list view. The value is `Equatable` so the coordinator can skip
/// redundant publishes.
public struct CommandPaletteCommandListRenderState: Equatable, Sendable {
    /// Monotonic version of the visible results, used to discard stale updates.
    public var resultsVersion: UInt64
    /// Text shown when the list is empty and an empty state should display.
    public var emptyStateText: String
    /// Stable identity for the list container, keyed off the palette query so
    /// SwiftUI resets scroll position on a list-identity change.
    public var listIdentity: String
    /// The rendered rows, in display order.
    public var rows: [CommandPaletteRenderResultRow]
    /// Index of the currently selected row.
    public var selectedIndex: Int
    /// Whether the empty-state text should be shown when `rows` is empty.
    public var shouldShowEmptyState: Bool
    /// Identity of the row to scroll into view, if any.
    public var scrollTargetID: String?
    /// Anchor used when scrolling `scrollTargetID` into view.
    public var scrollTargetAnchor: UnitPoint?

    /// Creates a render state snapshot.
    public init(
        resultsVersion: UInt64 = 0,
        emptyStateText: String = "",
        listIdentity: String = "switcher",
        rows: [CommandPaletteRenderResultRow] = [],
        selectedIndex: Int = 0,
        shouldShowEmptyState: Bool = false,
        scrollTargetID: String? = nil,
        scrollTargetAnchor: UnitPoint? = nil
    ) {
        self.resultsVersion = resultsVersion
        self.emptyStateText = emptyStateText
        self.listIdentity = listIdentity
        self.rows = rows
        self.selectedIndex = selectedIndex
        self.shouldShowEmptyState = shouldShowEmptyState
        self.scrollTargetID = scrollTargetID
        self.scrollTargetAnchor = scrollTargetAnchor
    }

    /// The empty snapshot used as the coordinator's initial published value.
    public static let empty = CommandPaletteCommandListRenderState()
}
