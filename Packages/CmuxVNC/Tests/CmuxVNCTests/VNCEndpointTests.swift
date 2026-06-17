import XCTest
@testable import CmuxVNC

final class VNCEndpointTests: XCTestCase {
    func testBareHostDefaultsTo5900() {
        XCTAssertEqual(VNCEndpoint(string: "host.local"), VNCEndpoint(host: "host.local", port: 5900))
    }

    func testDisplayNumberMapsToPort() {
        XCTAssertEqual(VNCEndpoint(string: "host:1"), VNCEndpoint(host: "host", port: 5901))
        XCTAssertEqual(VNCEndpoint(string: "host:2"), VNCEndpoint(host: "host", port: 5902))
    }

    func testExplicitPort() {
        XCTAssertEqual(VNCEndpoint(string: "host:5999"), VNCEndpoint(host: "host", port: 5999))
    }

    func testDoubleColonRawPort() {
        XCTAssertEqual(VNCEndpoint(string: "host::5905"), VNCEndpoint(host: "host", port: 5905))
    }

    func testVncSchemeAndPassword() {
        XCTAssertEqual(
            VNCEndpoint(string: "vnc://secret@10.0.0.5:5901"),
            VNCEndpoint(host: "10.0.0.5", port: 5901, password: "secret")
        )
        XCTAssertEqual(
            VNCEndpoint(string: "vnc://:pw@box"),
            VNCEndpoint(host: "box", port: 5900, password: "pw")
        )
    }

    func testIPv6Literal() {
        XCTAssertEqual(VNCEndpoint(string: "[::1]:5902"), VNCEndpoint(host: "::1", port: 5902))
        XCTAssertEqual(VNCEndpoint(string: "[fe80::1]"), VNCEndpoint(host: "fe80::1", port: 5900))
    }

    func testTrailingPathStripped() {
        XCTAssertEqual(VNCEndpoint(string: "vnc://host:5901/ignored"), VNCEndpoint(host: "host", port: 5901))
    }

    func testEmptyIsNil() {
        XCTAssertNil(VNCEndpoint(string: "   "))
    }

    func testDisplayLabel() {
        XCTAssertEqual(VNCEndpoint(host: "h", port: 5901).displayLabel, "h:5901")
    }
}
