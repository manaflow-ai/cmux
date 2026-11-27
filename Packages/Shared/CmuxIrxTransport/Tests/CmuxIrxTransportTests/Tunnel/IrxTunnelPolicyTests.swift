import Foundation
import Testing

@testable import CmuxIrxTransport

@Suite("tunnel destination policy")
struct IrxTunnelPolicyTests {
    let loopbackOnly = IrxTunnelDestinationPolicy(allowsNonLoopbackHosts: false)
    let optedIn = IrxTunnelDestinationPolicy(allowsNonLoopbackHosts: true)

    @Test("loopback is allowed by default, without DNS")
    func loopbackAllowed() {
        #expect(loopbackOnly.evaluate(host: "127.0.0.1", port: 3000) == .connect([.loopbackV4]))
        #expect(loopbackOnly.evaluate(host: "127.8.9.10", port: 3000) == .connect([IrxTunnelIPAddress("127.8.9.10")!]))
        #expect(loopbackOnly.evaluate(host: "::1", port: 3000) == .connect([.loopbackV6]))
        #expect(loopbackOnly.evaluate(host: "[::1]", port: 3000) == .connect([.loopbackV6]))
        #expect(loopbackOnly.evaluate(host: "localhost", port: 5173) == .connect([.loopbackV4, .loopbackV6]))
        #expect(loopbackOnly.evaluate(host: "App.LocalHost.", port: 5173) == .connect([.loopbackV4, .loopbackV6]))
        // The unspecified address means this host, as browsers treat it.
        #expect(loopbackOnly.evaluate(host: "0.0.0.0", port: 80) == .connect([.loopbackV4]))
        #expect(loopbackOnly.evaluate(host: "::", port: 80) == .connect([.loopbackV6]))
        #expect(loopbackOnly.evaluate(host: "::ffff:127.0.0.1", port: 80)
            == .connect([IrxTunnelIPAddress("::ffff:127.0.0.1")!]))
    }

    @Test("other hosts are denied until the Mac opts in")
    func remoteNeedsOptIn() {
        #expect(loopbackOnly.evaluate(host: "192.168.1.20", port: 80) == .deny)
        #expect(loopbackOnly.evaluate(host: "example.com", port: 443) == .deny)
        #expect(loopbackOnly.evaluate(host: "2606:4700::1111", port: 443) == .deny)
        // Non-canonical IPv4 spellings are names, and names are not resolved.
        #expect(loopbackOnly.evaluate(host: "127.1", port: 80) == .deny)
        #expect(loopbackOnly.evaluate(host: "2130706433", port: 80) == .deny)

        #expect(optedIn.evaluate(host: "192.168.1.20", port: 80) == .connect([IrxTunnelIPAddress("192.168.1.20")!]))
        #expect(optedIn.evaluate(host: "Example.COM", port: 443) == .resolve("example.com"))
    }

    @Test("metadata and link-local are denied even when opted in")
    func metadataAlwaysDenied() {
        for policy in [loopbackOnly, optedIn] {
            #expect(policy.evaluate(host: "169.254.169.254", port: 80) == .deny)
            #expect(policy.evaluate(host: "169.254.1.1", port: 80) == .deny)
            #expect(policy.evaluate(host: "::ffff:169.254.169.254", port: 80) == .deny)
            #expect(policy.evaluate(host: "64:ff9b::a9fe:a9fe", port: 80) == .deny)
            #expect(policy.evaluate(host: "fd00:ec2::254", port: 80) == .deny)
            #expect(policy.evaluate(host: "100.100.100.200", port: 80) == .deny)
            #expect(policy.evaluate(host: "fe80::1", port: 80) == .deny)
            #expect(policy.evaluate(host: "fe80::1%en0", port: 80) == .deny)
            #expect(policy.evaluate(host: "224.0.0.1", port: 80) == .deny)
            #expect(policy.evaluate(host: "255.255.255.255", port: 80) == .deny)
            #expect(policy.evaluate(host: "0.1.2.3", port: 80) == .deny)
        }
    }

    @Test("resolved addresses are re-checked, so DNS cannot point past the policy")
    func resolvedAddressesFiltered() {
        let resolved = [
            IrxTunnelIPAddress("169.254.169.254")!,
            IrxTunnelIPAddress("10.0.0.5")!,
            IrxTunnelIPAddress("fe80::1")!,
            IrxTunnelIPAddress("10.0.0.5")!,
        ]
        #expect(optedIn.filterResolved(resolved) == [IrxTunnelIPAddress("10.0.0.5")!])
        #expect(loopbackOnly.filterResolved(resolved).isEmpty)
        #expect(optedIn.filterResolved([IrxTunnelIPAddress("169.254.169.254")!]).isEmpty)
    }

    @Test("invalid ports and empty hosts are denied")
    func invalidInputs() {
        #expect(optedIn.evaluate(host: "127.0.0.1", port: 0) == .deny)
        #expect(optedIn.evaluate(host: "127.0.0.1", port: 65_536) == .deny)
        #expect(optedIn.evaluate(host: "", port: 80) == .deny)
        #expect(optedIn.evaluate(host: String(repeating: "a", count: 300), port: 80) == .deny)
    }

    @Test("listener addresses map to loopback connect targets")
    func listenerMapping() {
        let listeners: [IrxListeningPortScanner.Listener] = [
            .init(port: 3000, address: IrxTunnelIPAddress("0.0.0.0")!, ipv6Only: false),
            .init(port: 3000, address: IrxTunnelIPAddress("::")!, ipv6Only: true),
            .init(port: 5173, address: IrxTunnelIPAddress("::1")!, ipv6Only: true),
            .init(port: 8080, address: IrxTunnelIPAddress("::")!, ipv6Only: true),
            .init(port: 9000, address: IrxTunnelIPAddress("127.0.0.2")!, ipv6Only: false),
            .init(port: 9100, address: IrxTunnelIPAddress("192.168.1.4")!, ipv6Only: false),
        ]
        #expect(IrxListeningPortScanner().reachableFromLoopback(listeners) == [
            IrxListeningPort(port: 3000, address: "127.0.0.1"),
            IrxListeningPort(port: 5173, address: "::1"),
            IrxListeningPort(port: 8080, address: "::1"),
            IrxListeningPort(port: 9000, address: "127.0.0.2"),
        ])
    }

    #if os(macOS)
    @Test("the native scanner sees a loopback listener this process opened")
    func scannerSeesOwnListener() throws {
        let server = try TunnelTestTCPServer(mode: .echo)
        defer { server.stop() }
        let ports = IrxListeningPortScanner().loopbackListeningPorts()
        #expect(ports.contains(IrxListeningPort(port: server.port, address: "127.0.0.1")), "\(ports.count) ports")
    }
    #endif
}
