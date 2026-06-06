#if os(iOS)
import Foundation

/// Errors produced while preparing or submitting mobile feedback.
public enum MobileFeedbackSubmissionError: Error {
    /// The feedback endpoint could not be resolved.
    case invalidEndpoint
    /// The server response was not an HTTP response or could not be interpreted.
    case invalidResponse
    /// The server rejected the submission with a non-2xx HTTP status code.
    case rejected(statusCode: Int)
    /// A selected photo could not be read from PhotosPicker.
    case photoReadFailed
    /// A selected photo could not be compressed within the upload budget.
    case photoPreparationFailed
    /// Diagnostics text could not be prepared within the upload budget.
    case diagnosticsPreparationFailed
    /// URL loading failed before the server returned an HTTP response.
    case transport(URLError)
}
#endif
