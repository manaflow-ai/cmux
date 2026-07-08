public import Foundation

/// Errors thrown by the Chromium runtime integration.
public enum ChromiumRuntimeError: Error, Sendable {
    /// No valid runtime directory was found; carries every directory that was searched.
    case runtimeNotFound(searched: [URL])
    /// A required file was missing from a runtime directory.
    case invalidRuntimeDirectory(URL, missing: String)
    /// `dlopen` failed for the runtime dylib; carries the loader diagnostic.
    case libraryLoadFailed(String)
    /// A required symbol was missing from the runtime dylib.
    case symbolMissing(String)
    /// `owl_fresh_mojo_global_init` returned a nonzero status.
    case initializationFailed(code: Int32)
    /// The runtime thread has not been started, or failed to start.
    case runtimeUnavailable
    /// `owl_fresh_mojo_session_create` returned null.
    case sessionCreateFailed
    /// The session was closed before or during the call.
    case sessionClosed
    /// A runtime call reported an error; carries the runtime's message.
    case callFailed(String)
}

extension ChromiumRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .runtimeNotFound(let searched):
            let paths = searched.map(\.path).joined(separator: ", ")
            return "No OWL Chromium runtime found. Searched: \(paths)"
        case .invalidRuntimeDirectory(let url, let missing):
            return "Runtime directory \(url.path) is missing \(missing)"
        case .libraryLoadFailed(let message):
            return "Failed to load Chromium runtime library: \(message)"
        case .symbolMissing(let name):
            return "Chromium runtime library is missing symbol \(name)"
        case .initializationFailed(let code):
            return "Chromium runtime initialization failed with code \(code)"
        case .runtimeUnavailable:
            return "Chromium runtime is not running"
        case .sessionCreateFailed:
            return "Failed to create a Chromium session"
        case .sessionClosed:
            return "The Chromium session is closed"
        case .callFailed(let message):
            return "Chromium runtime call failed: \(message)"
        }
    }
}
