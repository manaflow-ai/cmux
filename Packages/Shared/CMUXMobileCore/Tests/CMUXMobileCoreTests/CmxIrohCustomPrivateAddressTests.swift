import Foundation
import Testing
@testable import CMUXMobileCore

@Test func customPrivateAddressCanonicalizesNumericIPOnly() throws {
    let ipv4 = try CmxIrohCustomPrivateAddress("10.0.0.8")
    #expect(ipv4.value == "10.0.0.8")
    #expect(ipv4.family == .ipv4)
    #expect(ipv4.socketAddress(port: 49_152) == "10.0.0.8:49152")

    let ipv6 = try CmxIrohCustomPrivateAddress("fd00:0:0:0:0:0:0:8")
    #expect(ipv6.value == "fd00::8")
    #expect(ipv6.family == .ipv6)
    #expect(ipv6.socketAddress(port: 49_152) == "[fd00::8]:49152")
}

@Test func customPrivateAddressRejectsCoordinatesAndUnsafeAddresses() {
    for value in [
        "private.example.com",
        "10.0.0.8:49152",
        "[fd00::8]:49152",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
        "::",
        "169.254.1.2",
        "fe80::1",
        "ff02::1",
        "fd00::1%en0",
    ] {
        #expect(
            throws: CmxIrohCustomPrivateAddressError.invalidAddress,
            Comment(rawValue: value)
        ) {
            _ = try CmxIrohCustomPrivateAddress(value)
        }
    }
}

@Test func customPrivateAddressDecodeRevalidatesFamily() throws {
    let valid = Data(#"{"value":"10.0.0.8","family":"ipv4"}"#.utf8)
    #expect(try JSONDecoder().decode(CmxIrohCustomPrivateAddress.self, from: valid).value
        == "10.0.0.8")

    let tampered = Data(#"{"value":"10.0.0.8","family":"ipv6"}"#.utf8)
    #expect(throws: CmxIrohCustomPrivateAddressError.invalidAddress) {
        _ = try JSONDecoder().decode(CmxIrohCustomPrivateAddress.self, from: tampered)
    }
}
