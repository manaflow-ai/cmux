internal import Foundation

/// Decodes v2 request-envelope lines (was `parseV2SocketRequest` and the
/// inline envelope parse in `processV2Command`).
///
/// Two entry points with deliberately different contracts, faithful to the
/// legacy call sites:
/// - `lenientRequest(fromLine:)` — the socket-worker fast path. Trims the
///   line, requires a `{` prefix, and returns `nil` on any defect so the line
///   falls through to v1 processing.
/// - `request(fromLine:)` — the main dispatcher. Parses the raw line untrimmed
///   and reports each defect as a distinct `ControlRequestParseError` so the
///   caller can return the matching protocol error response.
public struct ControlRequestParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Leniently decodes a line, returning `nil` unless it is a JSON object
    /// with a non-empty `method`.
    ///
    /// - Parameter line: The raw socket line.
    /// - Returns: The decoded envelope, or `nil` when the line is not a v2
    ///   request.
    public func lenientRequest(fromLine line: String) -> ControlRequest? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        guard let request = Self.request(fromObject: object), !request.method.isEmpty else {
            return nil
        }
        return request
    }

    /// Strictly decodes a line, classifying every defect.
    ///
    /// - Parameter line: The raw socket line (not trimmed, matching the legacy
    ///   dispatcher).
    /// - Returns: The decoded envelope, or the parse error to surface.
    public func request(fromLine line: String) -> Result<ControlRequest, ControlRequestParseError> {
        guard let data = line.data(using: .utf8) else {
            return .failure(.invalidUTF8)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.invalidJSON)
        }
        guard let dictionary = object as? [String: Any] else {
            return .failure(.notAnObject)
        }
        guard let request = Self.request(fromObject: dictionary) else {
            // Unreachable for JSONSerialization output; kept as a defensive
            // mirror of the legacy missing-method response.
            return .failure(.missingMethod(id: nil))
        }
        guard !request.method.isEmpty else {
            return .failure(.missingMethod(id: request.id))
        }
        return .success(request)
    }

    /// Builds the envelope from a decoded JSON object: trims `method`,
    /// defaults non-object `params` to empty, and bridges values to
    /// `JSONValue`.
    private static func request(fromObject dictionary: [String: Any]) -> ControlRequest? {
        let id: JSONValue?
        if let rawId = dictionary["id"] {
            guard let bridged = JSONValue(foundationObject: rawId) else { return nil }
            id = bridged
        } else {
            id = nil
        }
        let method = (dictionary["method"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var params: [String: JSONValue] = [:]
        if let rawParams = dictionary["params"] as? [String: Any] {
            guard let bridged = JSONValue(foundationObject: rawParams),
                  case .object(let values) = bridged else { return nil }
            params = values
        }
        return ControlRequest(id: id, method: method, params: params)
    }
}
