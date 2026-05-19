import XCTest
@testable import CMUXSocketProtocol

final class CMUXSocketProtocolTests: XCTestCase {
    func testJSONRPCVersionDetectionIsExact() {
        XCTAssertTrue(CMUXSocketProtocol.usesJSONRPC(["jsonrpc": "2.0"]))
        XCTAssertFalse(CMUXSocketProtocol.usesJSONRPC(["jsonrpc": "2.0 "]))
        XCTAssertFalse(CMUXSocketProtocol.usesJSONRPC(["jsonrpc": 2.0]))
    }

    func testParseRejectsMalformedJSONRPCID() {
        XCTAssertThrowsError(try CMUXSocketProtocol.parseV2SocketRequestObject([
            "jsonrpc": "2.0",
            "id": ["nested": "bad"],
            "method": "system.ping",
            "params": [String: Any]()
        ])) { error in
            XCTAssertEqual(error as? V2SocketRequestParseError, .malformedID)
        }
    }

    func testNotificationRequestSuppressesResponse() throws {
        let request = try CMUXSocketProtocol.parseV2SocketRequestObject([
            "jsonrpc": "2.0",
            "method": "system.ping",
            "params": [String: Any]()
        ])

        XCTAssertFalse(CMUXSocketProtocol.shouldWriteResponse(for: request))
    }

    func testMalformedRequestJSONRPCDetectionUsesTopLevelOnly() {
        XCTAssertTrue(CMUXSocketProtocol.malformedRequestUsesJSONRPC(#"{"jsonrpc":"2.0","id":"unfinished""#))
        XCTAssertFalse(CMUXSocketProtocol.malformedRequestUsesJSONRPC(#"{"method":"system.ping","params":{"jsonrpc":"2.0"}"#))
    }
}
