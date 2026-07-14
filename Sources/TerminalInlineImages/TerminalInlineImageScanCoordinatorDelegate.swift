import Foundation

@MainActor
protocol TerminalInlineImageScanCoordinatorDelegate: AnyObject {
    func scanCoordinatorRequest(workID: UUID) -> TerminalInlineImageScanRequest?
    func scanCoordinatorApply(
        _ detected: [DetectedImagePath]?,
        request: TerminalInlineImageScanRequest
    )
}
