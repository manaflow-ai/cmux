import Foundation

struct TranscriptActivityTimelinePresentation: Equatable {
    static let defaultItemLimit = 80

    let models: [TranscriptActivityDetailModel]
    let omittedCount: Int

    init(
        details: TranscriptActivityDetails,
        itemLimit: Int = Self.defaultItemLimit
    ) {
        let resolvedLimit = max(0, itemLimit)
        models = details.summary.items
            .prefix(resolvedLimit)
            .enumerated()
            .map { index, item in
                TranscriptActivityDetailModel(item: item, ordinal: index)
            }
        omittedCount = max(0, details.summary.items.count - models.count)
    }
}
