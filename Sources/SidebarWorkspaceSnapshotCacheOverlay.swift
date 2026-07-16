/// Produces a complete render-time value dictionary without changing its cache.
///
/// Cached entries retain their values and construction cost while the caller's
/// render-context predicate accepts them. The builder runs only for missing or
/// rejected entries, so a cold or stale cache cannot remove or misrender a row
/// while the parent-owned cache catches up on the next observation callback.
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
