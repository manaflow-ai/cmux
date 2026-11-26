import Testing
@testable import CMUXMobileCore

struct CmxIrohLocalSocketAddressTests {
    @Test func requiresExplicitPortAndCanonicalizesBothFamilies() throws {
        #expect(try CmxIrohLocalSocketAddress(" 192.168.1.5:58470 ").value == "192.168.1.5:58470")
        #expect(try CmxIrohLocalSocketAddress("[fd00:0:0::5]:443").value == "[fd00::5]:443")
    }
    @Test(arguments: ["192.168.1.5", "fd00::5", "[fd00::5]", "192.168.1.5:0", "192.168.1.5:65536",
        "mac.local:443", "127.0.0.1:443", "[fe80::1%en0]:443", "192.168.1.5:+443", "[fd00::5]:443:5"])
    func refusesIncompleteOrNonNumericRoutes(_ value: String) {
        #expect(throws: CmxIrohCustomPrivateAddressError.self) { try CmxIrohLocalSocketAddress(value) }
    }
}
