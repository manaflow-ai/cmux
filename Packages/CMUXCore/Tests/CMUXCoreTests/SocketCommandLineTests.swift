import CMUXCore
import XCTest

final class SocketCommandLineTests: XCTestCase {
    func testClassifiesJSONObjectLinesAsV2() throws {
        let line = try XCTUnwrap(SocketCommandLine("  {\"method\":\"system.ping\"}\n"))

        XCTAssertEqual(line.protocolVersion, .v2)
        XCTAssertEqual(line.trimmedValue, "{\"method\":\"system.ping\"}")
        XCTAssertNil(line.v1CommandName)
    }

    func testClassifiesNonJSONObjectLinesAsV1() throws {
        let line = try XCTUnwrap(SocketCommandLine("  LIST_WINDOWS now\n"))

        XCTAssertEqual(line.protocolVersion, .v1)
        XCTAssertEqual(line.trimmedValue, "LIST_WINDOWS now")
        XCTAssertEqual(line.v1CommandName, "list_windows")
    }

    func testReturnsNilForEmptyOrWhitespaceOnlyLines() throws {
        XCTAssertNil(SocketCommandLine(""))
        XCTAssertNil(SocketCommandLine("  \n\t  "))
    }

    func testV1CommandNameHandlesCommandWithoutArguments() throws {
        let line = try XCTUnwrap(SocketCommandLine("ping"))

        XCTAssertEqual(line.protocolVersion, .v1)
        XCTAssertEqual(line.v1CommandName, "ping")
    }
}
