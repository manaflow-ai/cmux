public import Foundation

/// Minimal HTTP seam used to test authenticated Realtime credential requests.
public protocol RealtimeVoiceHTTPSession: Sendable {
    /// Execute an HTTP request.
    /// - Parameter request: The prepared request.
    /// - Returns: Raw response bytes and metadata.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: RealtimeVoiceHTTPSession {}
