import Foundation

struct ClosedItemHistoryMenuProjection<Item> {
    let items: [Item]
    let isLimited: Bool

    static func project<Records: Sequence>(
        newestFirst records: Records,
        eligibleItemCount: Int,
        maxItemCount: Int?,
        isEligible: (Records.Element) -> Bool,
        transform: (Records.Element) -> Item
    ) -> Self {
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
            return Self(
                items: items,
                isLimited: eligibleItemCount > maxItemCount
            )
        }
        return Self(
            items: records.filter(isEligible).map(transform),
            isLimited: false
        )
    }
}
