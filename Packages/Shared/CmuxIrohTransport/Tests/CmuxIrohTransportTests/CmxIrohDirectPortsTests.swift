import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohDirectPortsTests {
    @Test
    func derivesIndependentAddressFamilyPorts() throws {
        let ports = try #require(CmxIrohDirectPorts(localDirectAddresses: [
            "0.0.0.0:50909",
            "[::]:54750",
            "100.82.214.112:50909",
            "[fd7a:115c:a1e0::4b36:d670]:54750",
            "198.51.100.20:60000",
        ]))

        let expected = try CmxIrohDirectPorts(ipv4: 50_909, ipv6: 54_750)
        #expect(ports == expected)
    }

    @Test
    func ambiguousFamilyIsOmittedRatherThanGuessed() throws {
        let ports = try #require(CmxIrohDirectPorts(localDirectAddresses: [
            "192.168.1.10:50909",
            "203.0.113.10:60000",
            "[fd7a:115c:a1e0::4b36:d670]:54750",
        ]))

        let expected = try CmxIrohDirectPorts(ipv6: 54_750)
        #expect(ports == expected)
    }

    @Test
    func decodedPortsRequireAtLeastOneNonzeroValue() throws {
        let decoder = JSONDecoder()
        #expect(throws: (any Error).self) {
            try decoder.decode(CmxIrohDirectPorts.self, from: Data("{}".utf8))
        }
        #expect(throws: (any Error).self) {
            try decoder.decode(
                CmxIrohDirectPorts.self,
                from: Data(#"{"ipv4":0}"#.utf8)
            )
        }
    }
}
