public import AppKit

/// The header's top-right panel toggles (``HomeHeaderPanelBar``), like Claude desktop's: the
/// host lists them with their state; an empty list shows none.
extension HomeNativeTranscriptView {
    /// Shows `items` at the header's top right; a click reports its id to ``onHeaderPanel``.
    public func setHeaderPanels(_ items: [HomeHeaderPanelItem]) {
        let size = headerPanels.intrinsicContentSize
        headerPanels.set(items)
        headerPanels.onToggle = { [weak self] id in self?.onHeaderPanel(id) }
        // The bar never invalidates its ancestor: a new size re-places it in the header from here.
        if headerPanels.intrinsicContentSize != size { headerPanels.superview?.needsLayout = true }
        let shown = transcript.headerTrailingAccessory != nil, showing = !items.isEmpty
        // The accessory's setter lays out the whole transcript host: assign it only when the bar comes or goes.
        guard showing != shown else { return }
        transcript.headerTrailingAccessory = showing ? headerPanels : nil
        // With no header the rows' top follows the toggles: the first-run panel moves with it.
        needsLayout = true
    }

    /// The panel toggles shown now (tests and `debug.home`).
    public var headerPanelItems: [HomeHeaderPanelItem] { transcript.headerTrailingAccessory == nil ? [] : headerPanels.items }
}
