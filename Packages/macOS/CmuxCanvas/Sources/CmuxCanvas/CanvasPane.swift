import Foundation

/// One pane on the canvas: an identifier, its frame, and the ordered panels
/// (tabs) it hosts.
///
/// Z-order is not stored here; it is the pane's position inside
/// ``CanvasLayout/panes`` (back to front). Tab order is `panelIds`, left to
/// right, and exactly one of them is selected while the pane is non-empty.
/// A pane never exists with zero panels — ``CanvasLayout`` removes a pane
/// when its last panel leaves.
public struct CanvasPane: Hashable, Codable, Sendable, Identifiable {
    /// The pane identifier.
    public let id: CanvasPaneID
    /// The pane frame in canvas coordinates.
    public var frame: CanvasRect
    /// The hosted panels (tabs), left to right. Never empty in a layout.
    public private(set) var panelIds: [CanvasPanelID]
    /// The selected tab. Always a member of ``panelIds``.
    public private(set) var selectedPanelId: CanvasPanelID

    /// Creates a single-tab pane from a panel, reusing the panel UUID as the
    /// pane identifier. This is the shape every pane starts in.
    ///
    /// - Parameters:
    ///   - id: The pane identifier (the founding panel's UUID).
    ///   - frame: The pane frame in canvas coordinates.
    public init(id: CanvasPaneID, frame: CanvasRect) {
        self.init(
            id: id,
            frame: frame,
            panelIds: [CanvasPanelID(rawValue: id.rawValue)],
            selectedPanelId: CanvasPanelID(rawValue: id.rawValue)
        )
    }

    /// Creates a pane with an explicit tab list (persistence restore).
    ///
    /// - Parameters:
    ///   - id: The pane identifier.
    ///   - frame: The pane frame in canvas coordinates.
    ///   - panelIds: Ordered tabs; must be non-empty.
    ///   - selectedPanelId: The selected tab; falls back to the first panel
    ///     when not a member of `panelIds`.
    public init(
        id: CanvasPaneID,
        frame: CanvasRect,
        panelIds: [CanvasPanelID],
        selectedPanelId: CanvasPanelID
    ) {
        precondition(!panelIds.isEmpty, "A canvas pane must host at least one panel")
        self.id = id
        self.frame = frame
        self.panelIds = panelIds
        self.selectedPanelId = panelIds.contains(selectedPanelId) ? selectedPanelId : panelIds[0]
    }

    /// Whether this pane hosts the given panel.
    public func contains(_ panelId: CanvasPanelID) -> Bool {
        panelIds.contains(panelId)
    }

    /// Selects a tab. Selecting a panel this pane does not host is a no-op.
    mutating func select(_ panelId: CanvasPanelID) {
        guard panelIds.contains(panelId) else { return }
        selectedPanelId = panelId
    }

    /// Inserts a panel at `index` (clamped; `nil` appends) and selects it
    /// when asked. Inserting a panel already present only re-selects it.
    mutating func insert(_ panelId: CanvasPanelID, at index: Int?, select: Bool) {
        if !panelIds.contains(panelId) {
            let clamped = Swift.min(Swift.max(index ?? panelIds.count, 0), panelIds.count)
            panelIds.insert(panelId, at: clamped)
        }
        if select {
            selectedPanelId = panelId
        }
    }

    /// Removes a panel, moving selection to the nearest remaining neighbor.
    /// Returns `false` when the panel was the last one (the caller must
    /// remove the whole pane instead).
    mutating func removePanel(_ panelId: CanvasPanelID) -> Bool {
        guard let index = panelIds.firstIndex(of: panelId) else { return true }
        guard panelIds.count > 1 else { return false }
        panelIds.remove(at: index)
        if selectedPanelId == panelId {
            selectedPanelId = panelIds[Swift.min(index, panelIds.count - 1)]
        }
        return true
    }
}
