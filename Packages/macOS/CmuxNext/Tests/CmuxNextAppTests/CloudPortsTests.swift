@testable import CmuxNextApp
import Testing

struct CloudPortsTests {
    @Test func parsesSsAndNetstatTables() {
        let table = "LISTEN 0 128 0.0.0.0:3000 0.0.0.0:*\nLISTEN 0 4096 [::]:22 [::]:*\nLISTEN 0 128 127.0.0.1:3000 0.0.0.0:*\ntcp 0 0 *:1337 *:* LISTEN\n"
        #expect(MachineListeningTCPRequest.ports(in: table) == [22, 1337, 3000])
        #expect(MachineListeningTCPRequest.ports(in: "").isEmpty)
    }
}
