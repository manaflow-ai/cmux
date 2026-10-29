import Testing
@testable import CmuxSurfaceCatalogModel

@Suite struct CloudPortInfrastructureTests {
    @Test("Container runtime listeners are not app ports", arguments: [33015, 45678])
    func infrastructureIsExcludedByOwner(port: Int) throws {
        let scan = try #require(CloudPortScanResult(socketListing:
            "LISTEN 0 4096 127.0.0.1:\(port) 0.0.0.0:* users:((\"containerd\",pid=1283,fd=12))"))
        #expect(scan.ports.isEmpty)
        #expect(scan.state == .empty(.noListeningService))
    }

    @Test("App listeners on the same port number remain discoverable")
    func appOnPreviouslyInternalPort() throws {
        let scan = try #require(CloudPortScanResult(socketListing:
            "LISTEN 0 128 127.0.0.1:33015 0.0.0.0:* users:((\"node\",pid=2000,fd=12))"))
        #expect(scan.ports == [33015])
        #expect(scan.state == .loopbackOnly)
    }

    @Test("Infrastructure does not hide app listeners or listeners with unavailable ownership")
    func mixedInventory() throws {
        let scan = try #require(CloudPortScanResult(socketListing: """
            LISTEN 0 4096 127.0.0.1:33015 0.0.0.0:* users:(("containerd",pid=1283,fd=12))
            LISTEN 0 4096 127.0.0.1:2375 0.0.0.0:* users:(("dockerd",pid=1200,fd=8))
            LISTEN 0 128 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=2000,fd=12))
            LISTEN 0 128 127.0.0.1:8081 0.0.0.0:*
            """))
        #expect(scan.ports == [3000, 8081])
        #expect(scan.loopbackOnlyPorts == [8081])
    }

    @Test("netstat ownership excludes container runtime listeners too")
    func netstatOwners() throws {
        let scan = try #require(CloudPortScanResult(socketListing: """
            tcp 0 0 127.0.0.1:33015 0.0.0.0:* LISTEN 1283/containerd
            tcp 0 0 127.0.0.1:3000 0.0.0.0:* LISTEN 2000/python3
            """))
        #expect(scan.ports == [3000])
    }
}
