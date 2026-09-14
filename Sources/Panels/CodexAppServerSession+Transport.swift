import Foundation

@MainActor
extension CodexAppServerSession {
    @discardableResult
    func sendRequest(method: String, params: Any, register: (Int) -> Void = { _ in }) async throws -> Int {
        let id = nextRequestID
        nextRequestID += 1
        register(id)
        try await sendJSONObject([
            "id": id,
            "method": method,
            "params": params
        ])
        return id
    }

    func sendNotification(method: String) async throws {
        try await sendJSONObject(["method": method])
    }

    func sendErrorResponse(id: Any, code: Int, message: String) async throws {
        try await sendJSONObject([
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    func sendJSONObject(_ object: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        try await writeData(data)
    }

    func requestID(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

}
