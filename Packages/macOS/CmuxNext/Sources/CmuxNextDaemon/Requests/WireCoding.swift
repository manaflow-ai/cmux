import Foundation

enum WireCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// A wire line decoder that counts into `recorder` (``WireDecoder``); with none it counts nothing.
    static func decoder(_ recorder: DaemonWireStats.Recorder? = nil) -> WireDecoder {
        WireDecoder(recorder: recorder)
    }

    /// Encodes `{id, cmd, ...fields}` as one line (no newline). The field
    /// names go to snake case; a ``VerbatimFieldsRequest``'s verbatim fields
    /// are added after that, unchanged (the snake case strategy also renames
    /// the keys inside nested objects).
    static func encodeRequest<R: DaemonRequest>(_ request: R, id: UInt64?) throws -> Data {
        let line = try encoder().encode(RequestEnvelope(id: id, request: request))
        guard let verbatim = request as? any VerbatimFieldsRequest,
              case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: line) else { return line }
        for (name, value) in verbatim.verbatimFields { fields.updateValue(value, forKey: name) }
        let plain = JSONEncoder()
        plain.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try plain.encode(JSONValue.object(fields))
    }

    /// Decodes the `data` of an `ok:true` response line.
    static func decodeResponse<R: Decodable>(_ type: R.Type, from line: Data, decoder: WireDecoder = WireCoding.decoder()) throws -> R {
        do {
            return try decoder.decode(ResponseEnvelope<R>.self, from: line).data
        } catch {
            throw DaemonError.malformedResponse("\(R.self): \(error)")
        }
    }

    /// Decodes the `data` of an `ok:true` response, counted on its connection.
    static func decodeResponse<R: Decodable>(_ type: R.Type, from response: LineTransport.Response) throws -> R {
        try decodeResponse(type, from: response.line, decoder: WireCoding.decoder(response.recorder))
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
        if R.self == EmptyResponse.self, !container.contains(.data), let empty = EmptyResponse() as? R {
            // Some acks omit `data`.
            data = empty
        } else {
            data = try container.decode(R.self, forKey: .data)
        }
    }
}
