import Foundation

struct ClosedItemHistoryMenuProjection<Item> {
    let items: [Item]
    let isLimited: Bool
}

enum ClosedItemHistoryMenuProjector {
    static func project<Records: Sequence, Item>(
        newestFirst records: Records,
        eligibleItemCount: Int,
        maxItemCount: Int?,
        isEligible: (Records.Element) -> Bool,
        transform: (Records.Element) -> Item
    ) -> ClosedItemHistoryMenuProjection<Item> {
        if let maxItemCount, maxItemCount >= 0 {
            let projectedItemCount = min(maxItemCount, eligibleItemCount)
            var items: [Item] = []
            items.reserveCapacity(projectedItemCount)
            if projectedItemCount > 0 {
                for record in records where isEligible(record) {
                    items.append(transform(record))
                    if items.count == projectedItemCount {
                        break
                    }
                }
            }
            return ClosedItemHistoryMenuProjection(
                items: items,
                isLimited: eligibleItemCount > maxItemCount
            )
        }
        return ClosedItemHistoryMenuProjection(
            items: records.filter(isEligible).map(transform),
            isLimited: false
        )
    }
}
