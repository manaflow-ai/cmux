/// Produces a complete render-time value dictionary without changing its cache.
///
/// Cached entries retain their values and construction cost. The builder runs
/// only for keys that are absent, so a cold cache cannot remove a row while the
/// parent-owned cache catches up on the next observation callback.
struct SidebarWorkspaceSnapshotCacheOverlay<Key: Hashable, Value> {
    let cachedValues: [Key: Value]

    func values<Element>(
        for elements: [Element],
        identifiedBy key: (Element) -> Key,
        isCachedValueValid: (Element, Value) -> Bool = { _, _ in true },
        makeValue: (Element) -> Value
    ) -> [Key: Value] {
        var mergedValues = cachedValues
        mergedValues.reserveCapacity(max(cachedValues.count, elements.count))

        for element in elements {
            let elementKey = key(element)
            if let cachedValue = mergedValues[elementKey],
               isCachedValueValid(element, cachedValue) {
                continue
            }
            mergedValues[elementKey] = makeValue(element)
        }

        return mergedValues
    }
}
