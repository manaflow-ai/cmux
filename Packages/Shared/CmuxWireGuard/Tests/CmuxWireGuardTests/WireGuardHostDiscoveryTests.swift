import CmuxWireGuard
import Foundation
import Network
import Testing

@Suite struct WireGuardHostDiscoveryTests {
    /// A host advertised with its id is found and resolved to ip:port; a
    /// different id is not.
    @Test func findsTheAdvertisedHostByID() async throws {
        let hostID = UUID().uuidString.lowercased()
        let listener = try NWListener(using: .udp)
        var txt = NWTXTRecord()
        txt["id"] = hostID
        listener.service = NWListener.Service(name: "cmux-test-\(hostID.prefix(6))", type: WireGuardHostDiscovery.serviceType,
                                              domain: nil, txtRecord: txt)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        defer { listener.cancel() }

        let found = await WireGuardHostDiscovery().endpoints(hostID: hostID, timeout: .seconds(10))
        let port = try #require(listener.port?.rawValue)
        #expect(found.count == 1)
        #expect(found.first?.hasSuffix(":\(port)") == true)

        let none = await WireGuardHostDiscovery().endpoints(hostID: "not-\(hostID)", timeout: .seconds(2))
        #expect(none.isEmpty)
    }
}
