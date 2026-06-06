import Foundation

enum MobileFeedbackSubmissionError: Error {
    case invalidEndpoint
    case invalidResponse
    case rejected(statusCode: Int)
    case photoReadFailed
    case photoPreparationFailed
    case diagnosticsPreparationFailed
    case transport(URLError)
}
