public import AppKit

/// The header's top-right panel toggles (``HomeHeaderPanelBar``), like Claude desktop's: the
/// host lists them with their state; an empty list shows none.
extension HomeNativeTranscriptView {
    /// Shows `items` at the header's top right; a click reports its id to ``onHeaderPanel``.
    public func setHeaderPanels(_ items: [HomeHeaderPanelItem]) {
        headerPanels.set(items)
        headerPanels.onToggle = { [weak self] id in self?.onHeaderPanel(id) }
        let shown = transcript.headerTrailingAccessory != nil
        transcript.headerTrailingAccessory = items.isEmpty ? nil : headerPanels
        // With no header the rows' top follows the toggles: the first-run panel moves with it.
        if shown == items.isEmpty { needsLayout = true }
    }

    /// The panel toggles shown now (tests and `debug.home`).
    public var headerPanelItems: [HomeHeaderPanelItem] { transcript.headerTrailingAccessory == nil ? [] : headerPanels.items }
}
