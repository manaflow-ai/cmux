import CMUXMobileCore
import Foundation

actor MobileDiffsTestHost {
    private var requests: [MobileDiffsTestRequest] = []
    private var errorCode: String?

    func setErrorCode(_ code: String?) {
        errorCode = code
    }

    func recordedRequests() -> [MobileDiffsTestRequest] {
        requests
    }

    func response(to request: MobileDiffsTestRequest) -> Data? {
        requests.append(request)
        if let errorCode {
            return try? Self.errorFrame(id: request.id, code: errorCode)
        }
        let result: [String: Any]
        switch request.method {
        case "mobile.workspace.diffs.summary":
            result = [
                "baseInfo": [
                    "kind": "workingTree",
                    "resolvedRef": "HEAD",
                    "describe": "HEAD",
                ],
                "totals": ["files": 1, "additions": 2, "deletions": 1],
                "files": [[
                    "path": "Sources/App.swift",
                    "oldPath": NSNull(),
                    "status": "modified",
                    "additions": 2,
                    "deletions": 1,
                    "isBinary": false,
                    "isLarge": false,
                    "patchDigest": "abc123",
                ]],
                "truncatedFileCount": 0,
            ]
        case "mobile.workspace.diffs.file":
            result = [
                "hunks": [],
                "isBinary": false,
                "tooLarge": false,
                "nextCursor": NSNull(),
            ]
        case "mobile.workspace.diffs.context":
            result = ["rows": ["line 4", "line 5"]]
        default:
            return try? Self.errorFrame(id: request.id, code: "method_not_found")
        }
        return try? Self.resultFrame(id: request.id, result: result)
    }

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private static func errorFrame(id: String?, code: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": ["code": code, "message": code],
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}
