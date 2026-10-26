import Foundation

/// A host-owned acpmux binary upload frame. The JSON header is bounded only by its u32 wire field;
/// file size and count are daemon policy, never this page transport.
nonisolated enum AgentPaneUploadError: Error, Equatable, Sendable { case rpc(String) }

nonisolated struct AcpmuxUploadFrame: Sendable, Equatable {
    enum DecodeError: Error { case invalidMagic, invalidHeader, invalidJSON, invalidPayload }

    let id: Int
    let sessionId: String
    let uploadId: String
    let offset: UInt64
    let bytes: Data

    init(id: Int, sessionId: String, uploadId: String, offset: UInt64, bytes: Data) {
        self.id = id
        self.sessionId = sessionId
        self.uploadId = uploadId
        self.offset = offset
        self.bytes = bytes
    }

    func encoded() throws -> Data {
        let header: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "_acpmux/file_put_data",
            "params": ["sessionId": sessionId, "uploadId": uploadId, "offset": offset],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              json.count <= Int(UInt32.max) else { throw DecodeError.invalidHeader }
        var data = Data("AMUP".utf8)
        var length = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(bytes)
        return data
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count >= 8, data.prefix(4) == Data("AMUP".utf8) else { return nil }
        let headerLength = data.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(headerLength) <= data.count - 8 else { return nil }
        let headerData = data.subdata(in: 8..<(8 + Int(headerLength)))
        guard let object = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              object["jsonrpc"] as? String == "2.0",
              object["method"] as? String == "_acpmux/file_put_data",
              let id = object["id"] as? Int,
              let params = object["params"] as? [String: Any],
              let sessionId = params["sessionId"] as? String,
              let uploadId = params["uploadId"] as? String,
              let offsetNumber = params["offset"] as? NSNumber else { return nil }
        return Self(id: id, sessionId: sessionId, uploadId: uploadId, offset: offsetNumber.uint64Value,
                    bytes: data.dropFirst(8 + Int(headerLength)))
    }
}
