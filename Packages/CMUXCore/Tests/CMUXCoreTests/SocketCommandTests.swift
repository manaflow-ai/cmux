import CMUXCore
import XCTest

final class SocketCommandTests: XCTestCase {
    func testCommandEncodesIDMethodAndParams() throws {
        let command = SocketCommand(
            id: "request-1",
            method: .workspaceCreate,
            params: WorkspaceCreateParams(name: "linux-port")
        )

        let data = try JSONEncoder().encode(command)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = try JSONDecoder().decode(SocketCommand<WorkspaceCreateParams>.self, from: data)

        XCTAssertEqual(object?["id"] as? String, "request-1")
        XCTAssertEqual(object?["method"] as? String, "workspace.create")
        XCTAssertEqual(decoded.id, "request-1")
        XCTAssertEqual(decoded.method, .workspaceCreate)
        XCTAssertEqual(decoded.params, WorkspaceCreateParams(name: "linux-port"))
    }

    func testCommandWithoutIDOrParamsOmitsOptionalKeys() throws {
        let command = SocketCommand<NoSocketParams>(method: .systemPing)

        let data = try JSONEncoder().encode(command)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["method"] as? String, "system.ping")
        XCTAssertNil(object?["id"])
        XCTAssertNil(object?["params"])
    }

    func testCommandDecodeRejectsInvalidMethod() throws {
        let data = #"{"id":"request-1","method":"","params":{}}"#.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(SocketCommand<NoSocketParams>.self, from: data))
    }
}

private struct WorkspaceCreateParams: Codable, Equatable, Sendable {
    let name: String
}
