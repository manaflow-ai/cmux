import Foundation
import UniformTypeIdentifiers

nonisolated enum BrowserDownloadHTTPStatusDecision: Equatable {
    case allow
    case reject(statusCode: Int)
}

nonisolated struct BrowserDownloadFilenameResolver {
    func httpStatusDecision(for response: URLResponse?) -> BrowserDownloadHTTPStatusDecision {
        .allow
    }

    func imageType(forImageData data: Data) -> UTType? {
        nil
    }

    func imageType(forDownloadedFileAt fileURL: URL) -> UTType? {
        nil
    }

    func suggestedFilename(
        suggestedFilename: String?,
        response: URLResponse?,
        sourceURL: URL,
        imageType: UTType?
    ) -> String {
        let filenameCandidate = suggestedFilename
            ?? response?.suggestedFilename
            ?? sourceURL.lastPathComponent
        let trimmed = filenameCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : trimmed
    }
}
