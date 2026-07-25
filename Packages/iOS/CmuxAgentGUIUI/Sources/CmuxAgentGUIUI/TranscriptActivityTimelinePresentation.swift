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
            .map(TranscriptActivityDetailModel.init(item:))
        omittedCount = max(0, details.summary.items.count - models.count)
    }
}
