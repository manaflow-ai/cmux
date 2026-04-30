import CMUXCore
import XCTest

final class SocketResponseTests: XCTestCase {
    func testSuccessResponseKeepsV2WireShape() throws {
        let response = SocketResponse(
            id: "request-1",
            ok: true,
            result: JSONValue.object(["version": .string("linux-port")])
        )

        let data = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = try JSONDecoder().decode(SocketResponse<JSONValue>.self, from: data)

        XCTAssertEqual(object?["id"] as? String, "request-1")
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual(decoded, response)
    }

    func testErrorResponseKeepsV2WireShape() throws {
        let response = SocketResponse<JSONValue>(
            id: "request-2",
            ok: false,
            error: SocketErrorPayload(
                code: "unknown_method",
                message: "Unknown method",
                data: .object(["method": .string("missing.command")])
            )
        )

        let data = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let decoded = try JSONDecoder().decode(SocketResponse<JSONValue>.self, from: data)

        XCTAssertEqual(object?["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "unknown_method")
        XCTAssertEqual(error?["message"] as? String, "Unknown method")
        XCTAssertEqual(decoded, response)
    }

    func testNilResponseIDEncodesAsNull() throws {
        let response = SocketResponse(id: nil, ok: true, result: JSONValue.object([:]))

        let data = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertTrue(object?["id"] is NSNull)
    }
}
