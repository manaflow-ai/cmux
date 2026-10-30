import Foundation

nonisolated extension AcpmuxPaneMethods {
    /// Only references have a metadata exception. Bytes and nested metadata stay outside it.
    static func promptUploadMeta(_ block: [String: Any]) -> [String: Any]? {
        guard block["data"] == nil, block["blob"] == nil, block["resource"] == nil,
              let type = block["type"] as? String, type == "image" || type == "resource_link",
              let meta = block["_meta"] as? [String: Any],
              let acpmux = meta["acpmux"] as? [String: Any],
              let upload = acpmux["upload"] as? [String: Any],
              Set(upload.keys) == ["uploadId", "fileName"],
              let uploadId = upload["uploadId"] as? String, UUID(uuidString: uploadId) != nil,
              let fileName = upload["fileName"] as? String, !fileName.isEmpty
        else { return nil }
        if type == "resource_link" {
            guard block["uri"] as? String == "acpmux-upload:\(uploadId)" else { return nil }
        } else {
            guard block["uri"] == nil else { return nil }
        }
        return ["acpmux": ["upload": ["uploadId": uploadId, "fileName": fileName]]]
    }
}
