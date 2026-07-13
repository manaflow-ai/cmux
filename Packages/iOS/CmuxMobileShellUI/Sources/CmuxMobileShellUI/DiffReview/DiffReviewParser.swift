import CmuxDiffModel

struct DiffReviewParser: Sendable {
    private let unifiedDiffParser: UnifiedDiffParser

    init(unifiedDiffParser: UnifiedDiffParser = UnifiedDiffParser()) {
        self.unifiedDiffParser = unifiedDiffParser
    }

    func parse(_ response: DiffFilePatch) async -> DiffParseResult {
        let unifiedDiffParser = unifiedDiffParser
        let task = Task.detached(priority: .userInitiated) {
            unifiedDiffParser.parse(response.unifiedDiff, isTruncated: response.isTruncated)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
