import Foundation

/// How a single chunk of an OpenCode subprocess's output should be handled.
enum OpenCodeProcessOutputDisposition: Equatable {
    case emit
    case suppress
    case serverURL(URL)

    /// Classifies one OpenCode output chunk: a server-URL announcement, a
    /// suppressed stdout log line, or assistant output to emit.
    static func classify(text: String, stream: String) -> OpenCodeProcessOutputDisposition {
        if let baseURL = OpenCodeServerClient.serverURL(from: text) {
            return .serverURL(baseURL)
        }
        if stream == "stdout" {
            return .suppress
        }
        return .emit
    }

    /// Whether an EOF on the OpenCode event stream should fail the session:
    /// only when the session was not cancelled and its process is still running.
    static func eventStreamEOFRequiresFailure(isCancelled: Bool, processIsRunning: Bool) -> Bool {
        !isCancelled && processIsRunning
    }
}
