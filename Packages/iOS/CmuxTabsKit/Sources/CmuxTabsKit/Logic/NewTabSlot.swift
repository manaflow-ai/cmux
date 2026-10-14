/// The card (+) adds to the grid while the host creates the tab.
///
/// A data source can list the new tab (for example from a server event)
/// before `createTab` returns. The placeholder card therefore stands in only
/// until an item that was not in the grid when (+) was pressed appears; that
/// item then takes the placeholder's slot in place (same index, same frame),
/// and the grid never shows both cards.
struct NewTabSlot: Equatable, Sendable {
    /// Item ids in the grid when (+) was pressed.
    let baseline: [String]

    /// The host's new item: the first id not in the baseline, once it is listed.
    func created(in ids: [String]) -> String? {
        let known = Set(baseline)
        return ids.first { !known.contains($0) }
    }

    /// The placeholder card shows until the created item is listed.
    func showsPlaceholder(in ids: [String]) -> Bool { created(in: ids) == nil }

    /// The placeholder's index: after every listed item (all of them baseline
    /// items while it shows), so it is the slot the created item is appended to.
    func placeholderIndex(in ids: [String]) -> Int { ids.count }

    /// Cards in the grid: exactly one for the new tab at any moment.
    func cardCount(in ids: [String]) -> Int { ids.count + (showsPlaceholder(in: ids) ? 1 : 0) }

    /// The grid slot the new tab's zoom lands on: the created item's index
    /// once it is listed, else the placeholder's.
    func zoomIndex(in ids: [String]) -> Int {
        if let id = created(in: ids), let i = ids.firstIndex(of: id) { return i }
        return placeholderIndex(in: ids)
    }
}
