import Foundation

extension LineTransport {
    /// Routing fields of a raw protocol line or a `cmux.protocol/2`
    /// response. Resource responses carry the request id as a decimal
    /// string and a structured `error` object.
    struct Envelope: Decodable {
        var id: UInt64?
        var ok: Bool?
        var event: String?
        var error: String?
        var errorCode: String?
        /// `stream_item` or `stream_end` of a `cmux.protocol/2` stream.
        var type: String?
        var streamID: String?

        enum CodingKeys: String, CodingKey {
            case id, ok, event, error, type
            case errorCode = "error_code"
            case streamID = "stream_id"
        }

        private struct ResourceError: Decodable {
            var code: String?
            var message: String?
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? c.decodeIfPresent(UInt64.self, forKey: .id) {
                id = number
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .id) {
                id = UInt64(text)
            }
            ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
            (event, streamID) = (try? c.decodeIfPresent(String.self, forKey: .event), try? c.decodeIfPresent(String.self, forKey: .streamID))
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            errorCode = try? c.decodeIfPresent(String.self, forKey: .errorCode)
            if let text = try? c.decodeIfPresent(String.self, forKey: .error) {
                error = text
            } else if let structured = try? c.decodeIfPresent(ResourceError.self, forKey: .error) {
                error = structured.message ?? structured.code
                errorCode = errorCode ?? structured.code
            }
        }
    }
}
