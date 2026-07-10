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
        let eligibleRecords = records.filter(isEligible)
        if let maxItemCount,
           maxItemCount >= 0,
           eligibleItemCount > maxItemCount {
            return ClosedItemHistoryMenuProjection(
                items: eligibleRecords.prefix(maxItemCount).map(transform),
                isLimited: true
            )
        }
        return ClosedItemHistoryMenuProjection(
            items: eligibleRecords.map(transform),
            isLimited: false
        )
    }
}
