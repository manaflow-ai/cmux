import Foundation

enum WireCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Encodes `{id, cmd, ...fields}` as one line (no newline).
    static func encodeRequest<R: DaemonRequest>(_ request: R, id: UInt64?) throws -> Data {
        try encoder().encode(RequestEnvelope(id: id, request: request))
    }

    /// Decodes the `data` of an `ok:true` response line.
    static func decodeResponse<R: Decodable>(_ type: R.Type, from line: Data) throws -> R {
        do {
            return try decoder().decode(ResponseEnvelope<R>.self, from: line).data
        } catch {
            throw DaemonError.malformedResponse("\(R.self): \(error)")
        }
    }
}

struct RequestEnvelope<R: DaemonRequest>: Encodable {
    var id: UInt64?
    var request: R

    enum CodingKeys: String, CodingKey {
        case id, cmd
    }

    func encode(to encoder: any Encoder) throws {
        try request.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(R.command, forKey: .cmd)
    }
}

struct ResponseEnvelope<R: Decodable>: Decodable {
    var data: R

    enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if R.self == EmptyResponse.self, !container.contains(.data) {
            // Some acks omit `data`.
            // crash-allow: checked on the line above (R.self == EmptyResponse.self).
            data = EmptyResponse() as! R
        } else {
            data = try container.decode(R.self, forKey: .data)
        }
    }
}
