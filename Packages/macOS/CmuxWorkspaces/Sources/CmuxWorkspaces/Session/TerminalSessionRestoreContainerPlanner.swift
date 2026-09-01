public import Foundation

/// A persistence-format-neutral description of one panel in a split
/// container.
public struct TerminalSessionRestorePanelDescriptor: Sendable, Equatable {
    /// Stable panel identity used by the layout tree.
    public let id: UUID
    /// Whether restoring the panel would recreate a terminal surface.
    public let containsTerminalSurface: Bool

    /// Creates a panel descriptor for restore planning.
    public init(id: UUID, containsTerminalSurface: Bool) {
        self.id = id
        self.containsTerminalSurface = containsTerminalSurface
    }
}

/// The two orientations used by a persisted split layout.
public enum TerminalSessionRestoreSplitOrientation: String, Sendable, Equatable {
    /// A split laid out from left to right.
    case horizontal
    /// A split laid out from top to bottom.
    case vertical
}

/// A layout tree that contains only the identifiers and geometry needed for
/// terminal-session filtering. App-specific persistence DTOs are adapted at
/// the boundary in the app target.
public indirect enum TerminalSessionRestoreLayout: Sendable, Equatable {
    /// A pane and its ordered panel tabs.
    case pane(
        panelIDs: [UUID],
        selectedPanelID: UUID?,
        isFullWidthTabMode: Bool?
    )
    /// A split node with its original divider position.
    case split(
        orientation: TerminalSessionRestoreSplitOrientation,
        dividerPosition: Double,
        first: TerminalSessionRestoreLayout,
        second: TerminalSessionRestoreLayout
    )
}

/// The result of filtering one split container.
public struct TerminalSessionRestoreContainerPlan: Sendable, Equatable {
    /// Panel identifiers that survive filtering, in their original order.
    public let retainedPanelIDs: [UUID]
    /// Focused panel after removed panels are accounted for.
    public let focusedPanelID: UUID?
    /// Layout tree with removed panels and empty branches collapsed.
    public let layout: TerminalSessionRestoreLayout

    /// Creates a container restore plan.
    public init(
        retainedPanelIDs: [UUID],
        focusedPanelID: UUID?,
        layout: TerminalSessionRestoreLayout
    ) {
        self.retainedPanelIDs = retainedPanelIDs
        self.focusedPanelID = focusedPanelID
        self.layout = layout
    }
}

extension TerminalSessionRestorePlanner {
    /// Computes retained panels, focus, and split geometry in linear time in
    /// the panel/layout collections. Empty split branches collapse so callers
    /// can restore a valid tree without knowing the concrete persistence type.
    public func planContainer(
        panels: [TerminalSessionRestorePanelDescriptor],
        focusedPanelID: UUID?,
        layout: TerminalSessionRestoreLayout
    ) -> TerminalSessionRestoreContainerPlan? {
        let retainedPanelIDs = restoreTerminalSessions
            ? panels.map(\.id)
            : panels.compactMap { $0.containsTerminalSurface ? nil : $0.id }
        guard !retainedPanelIDs.isEmpty else { return nil }

        let retainedIDs = Set(retainedPanelIDs)
        let resolvedFocusedPanelID = focusedPanelID.flatMap {
            retainedIDs.contains($0) ? $0 : retainedPanelIDs.first
        }
        let filteredLayout = filterLayout(layout, retaining: retainedIDs)
            ?? .pane(
                panelIDs: retainedPanelIDs,
                selectedPanelID: retainedPanelIDs.first,
                isFullWidthTabMode: nil
            )
        return TerminalSessionRestoreContainerPlan(
            retainedPanelIDs: retainedPanelIDs,
            focusedPanelID: resolvedFocusedPanelID,
            layout: filteredLayout
        )
    }

    private func filterLayout(
        _ layout: TerminalSessionRestoreLayout,
        retaining panelIDs: Set<UUID>
    ) -> TerminalSessionRestoreLayout? {
        switch layout {
        case let .pane(ids, selectedPanelID, isFullWidthTabMode):
            let retainedIDs = ids.filter { panelIDs.contains($0) }
            guard !retainedIDs.isEmpty else { return nil }
            return .pane(
                panelIDs: retainedIDs,
                selectedPanelID: selectedPanelID.flatMap {
                    panelIDs.contains($0) ? $0 : retainedIDs.first
                },
                isFullWidthTabMode: isFullWidthTabMode
            )
        case let .split(orientation, dividerPosition, first, second):
            let filteredFirst = filterLayout(first, retaining: panelIDs)
            let filteredSecond = filterLayout(second, retaining: panelIDs)
            switch (filteredFirst, filteredSecond) {
            case let (first?, second?):
                return .split(
                    orientation: orientation,
                    dividerPosition: dividerPosition,
                    first: first,
                    second: second
                )
            case let (first?, nil):
                return first
            case let (nil, second?):
                return second
            case (nil, nil):
                return nil
            }
        }
    }
}
