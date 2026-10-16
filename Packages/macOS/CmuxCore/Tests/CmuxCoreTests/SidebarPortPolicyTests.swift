import Testing
@testable import CmuxCore

@Suite("Sidebar listener port policy")
struct SidebarPortPolicyTests {
    @Test("Loopback dynamic ports are hidden", arguments: [
        [127, 0, 0, 1], [127, 0, 0, 2], [127, 255, 255, 254],
        Array(repeating: 0, count: 15) + [1],
        Array(repeating: 0, count: 10) + [255, 255, 127, 0, 0, 1],
    ], [49_152, 50_000, 65_535])
    func loopbackDynamicPorts(address: [UInt8], port: Int) {
        #expect(!SidebarPortPolicy().includes(port: port, addressBytes: address))
    }

    @Test("Development ports below the dynamic range remain visible", arguments: [1, 3000, 5173, 8080, 49_151])
    func developmentPorts(port: Int) {
        #expect(SidebarPortPolicy().includes(port: port, addressBytes: [127, 0, 0, 1]))
        #expect(SidebarPortPolicy().includes(port: port, addressBytes: Array(repeating: 0, count: 15) + [1]))
    }

    @Test("Wildcard and non-loopback dynamic ports remain visible", arguments: [
        [0, 0, 0, 0], [192, 168, 1, 2], [126, 0, 0, 1], [128, 0, 0, 1],
        Array(repeating: 0, count: 16),
        [32, 1, 13, 184] + Array(repeating: 0, count: 11) + [1],
        Array(repeating: 0, count: 10) + [255, 255, 192, 168, 1, 2],
    ], [49_152, 50_000, 65_535])
    func nonLoopbackDynamicPorts(address: [UInt8], port: Int) {
        #expect(SidebarPortPolicy().includes(port: port, addressBytes: address))
    }

    @Test("Invalid ports are rejected", arguments: [Int.min, -1, 0, 65_536, Int.max])
    func invalidPorts(port: Int) {
        #expect(!SidebarPortPolicy().includes(port: port, addressBytes: [0, 0, 0, 0]))
    }

    @Test("Unknown bind addresses do not hide valid listeners")
    func unknownAddress() {
        #expect(SidebarPortPolicy().includes(port: 50_000, addressBytes: []))
    }
}
