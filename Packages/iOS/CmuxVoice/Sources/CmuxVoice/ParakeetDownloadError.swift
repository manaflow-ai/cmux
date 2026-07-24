import Foundation

enum ParakeetDownloadError: Error, LocalizedError, Sendable {
    case emptyFileList
    case httpStatus(path: String, statusCode: Int)
    case invalidFileList
    case invalidResponse(path: String)
    case missingFileSize(path: String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .emptyFileList:
            return "No required Parakeet model files were listed."
        case .httpStatus(let path, let statusCode):
            return "Parakeet model download failed for \(path) with HTTP \(statusCode)."
        case .invalidFileList:
            return "Parakeet model file list could not be decoded."
        case .invalidResponse(let path):
            return "Parakeet model download returned an invalid response for \(path)."
        case .missingFileSize(let path):
            return "Parakeet model file \(path) did not include a size."
        case .sizeMismatch(let path, let expected, let actual):
            return "Parakeet model file \(path) was \(actual) bytes, expected \(expected) bytes."
        }
    }

    var isTransient: Bool {
        switch self {
        case .httpStatus(_, let statusCode):
            return statusCode == 429 || statusCode >= 500
        case .emptyFileList, .invalidFileList, .invalidResponse, .missingFileSize, .sizeMismatch:
            return false
        }
    }
}
