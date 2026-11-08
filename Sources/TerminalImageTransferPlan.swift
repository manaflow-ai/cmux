import Foundation

enum TerminalImageTransferPlan: Equatable {
    case insertText(String)
    case insertTextSegments([String], interSegmentDelay: TimeInterval)
    case uploadFiles([URL], TerminalRemoteUploadTarget)
    case pasteCloudImages([URL])
    case reject
}
