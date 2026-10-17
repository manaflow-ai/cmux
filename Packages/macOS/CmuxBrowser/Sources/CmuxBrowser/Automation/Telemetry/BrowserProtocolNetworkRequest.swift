import Foundation

/// One request a Chromium page made, from the `Network` domain.
/// A redirect ends one entry (``State/redirected``) and starts
/// the next with the same request id.
public struct BrowserProtocolNetworkRequest: Equatable, Sendable {
    /// Where the request is.
    public enum State: String, Sendable {
        case pending
        case redirected
        case finished
        case failed
    }

    public var requestID: String
    public var url: String
    public var method: String
    /// The protocol's resource type, lowercased (`document`, `fetch`, `xhr`, ...).
    public var resourceType: String
    public var state: State = .pending
    /// Milliseconds since 1970 when the request was sent.
    public var timestampMS: Double
    /// The protocol's monotonic send time in seconds (for the duration).
    var startMonotonic: Double?
    public var status: Int?
    public var statusText: String?
    public var mimeType: String?
    public var remoteAddress: String?
    public var fromCache = false
    public var errorText: String?
    public var canceled = false
    public var encodedDataLength: Double?
    /// From send to finish or failure.
    public var durationMS: Double?

    public init(requestID: String, url: String, method: String, resourceType: String, timestampMS: Double) {
        self.requestID = requestID
        self.url = url
        self.method = method
        self.resourceType = resourceType
        self.timestampMS = timestampMS
    }

    /// The `browser.network.requests` item.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "request_id": requestID,
            "url": url,
            "method": method,
            "resource_type": resourceType,
            "state": state.rawValue,
            "timestamp_ms": timestampMS,
            "from_cache": fromCache,
        ]
        if let status { object["status"] = status }
        if let statusText, !statusText.isEmpty { object["status_text"] = statusText }
        if let mimeType, !mimeType.isEmpty { object["mime_type"] = mimeType }
        if let remoteAddress, !remoteAddress.isEmpty { object["remote_address"] = remoteAddress }
        if let errorText { object["error_text"] = errorText }
        if canceled { object["canceled"] = true }
        if let encodedDataLength { object["encoded_data_length"] = encodedDataLength }
        if let durationMS { object["duration_ms"] = durationMS }
        return object
    }
}
