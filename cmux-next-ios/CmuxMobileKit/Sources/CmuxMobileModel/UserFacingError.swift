import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What an alert, label, toast or failure state says for an error.
///
/// Never `String(describing: error)` or a bridged `localizedDescription` for a
/// Swift error: those read `LinkError(code: "timeout", message: …)` or "The
/// operation couldn't be completed. (… error 1.)". An error with a sentence of
/// its own says it (`LocalizedError`, or an Apple error's own description);
/// anything else says `fallback`. Logs and telemetry keep the raw error.
public enum UserFacingError {
    /// Said when an error has no sentence of its own.
    public static let generic = "Something went wrong. Try again."

    public static func message(_ error: any Error, fallback: String = generic) -> String {
        if error is CancellationError { return fallback }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Connect to the internet and try again."
            case .timedOut:
                return "The connection timed out. Try again."
            case .cancelled:
                return fallback
            default:
                break
            }
        }
        if let text = (error as? any LocalizedError)?.errorDescription, let shown = displayable(text) { return shown }
        // An Apple error (URLError, CocoaError, WebKit) carries its own sentence; a Swift
        // error that is not `LocalizedError` has none here, only the bridged boilerplate.
        if let text = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String, let shown = displayable(text) {
            return shown
        }
        return fallback
    }

    /// `text` trimmed, or nil when it is empty or reads as a dump (a type name,
    /// the bridged "couldn't be completed" boilerplate, JSON).
    public static func displayable(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dumps = ["couldn’t be completed. (", "couldn't be completed. (", "Error(", "Error.", "(code:", "Optional(", "{\""]
        if dumps.contains(where: { trimmed.contains($0) }) { return nil }
        return trimmed
    }

    /// Whether a message a server or the Mac sent reads as a sentence for a person:
    /// it starts with a capital letter, has words, and holds no code, JSON or markup.
    public static func isProse(_ text: String) -> Bool {
        guard let trimmed = displayable(text), trimmed.count <= 240, trimmed.contains(" "),
              let first = trimmed.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
        let markers = ["{", "}", "<", ">", "_", "://", "HTTP ", "http_"]
        return !markers.contains(where: { trimmed.contains($0) })
    }
}
