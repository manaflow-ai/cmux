import Foundation
import Testing
@testable import CmuxMobileTransport

private func interface(_ name: String, _ address: String) -> NetworkInterfaceAddress {
    NetworkInterfaceAddress(interfaceName: name, address: address)
}

// MARK: - Snapshot classification

@Test func utunInterfaceWithCGNATAddressIsActive() {
    let snapshot = [
        interface("lo0", "127.0.0.1"),
        interface("en0", "192.168.1.20"),
        interface("utun4", "100.101.7.23"),
    ]
    #expect(TailscaleTailnetDetector.status(forInterfaces: snapshot) == .active)
}

@Test func utunInterfaceWithTailscaleULAIsActive() {
    let snapshot = [
        interface("en0", "192.168.1.20"),
        interface("utun4", "fd7a:115c:a1e0:ab12:4843:cd96:6253:1234"),
    ]
    #expect(TailscaleTailnetDetector.status(forInterfaces: snapshot) == .active)
}

@Test func scopedTailscaleULAStillClassifiesAsActive() {
    // getnameinfo appends "%zone" to scoped IPv6 addresses.
    let snapshot = [interface("utun3", "fd7a:115c:a1e0::2%utun3")]
    #expect(TailscaleTailnetDetector.status(forInterfaces: snapshot) == .active)
}

@Test func cgnatAddressOnNonTunnelInterfaceIsNotATailnet() {
    // Carrier CGNAT on cellular must not read as Tailscale.
    let snapshot = [
        interface("pdp_ip0", "100.80.12.9"),
        interface("en0", "100.64.0.7"),
    ]
    #expect(TailscaleTailnetDetector.status(forInterfaces: snapshot) == .inactiveOrNotInstalled)
}

@Test func utunWithNonTailscaleAddressesIsNotATailnet() {
    // A different VPN's tunnel (private range, link-local v6, other ULA).
    let snapshot = [
        interface("utun0", "10.8.0.2"),
        interface("utun1", "fe80::ce81:b1c:bd2c:69e"),
        interface("utun2", "fd00:abcd::1"),
    ]
    #expect(TailscaleTailnetDetector.status(forInterfaces: snapshot) == .inactiveOrNotInstalled)
}

@Test func emptySnapshotIsInactiveOrNotInstalled() {
    #expect(TailscaleTailnetDetector.status(forInterfaces: []) == .inactiveOrNotInstalled)
}

@Test func failedEnumerationIsUnknown() {
    #expect(TailscaleTailnetDetector.status(forInterfaces: nil) == .unknown)
}

// MARK: - Address-range edges

@Test(arguments: [
    "100.64.0.0",
    "100.64.0.1",
    "100.100.100.100",
    "100.127.255.255",
])
func cgnatRangeMembersMatch(address: String) {
    #expect(TailscaleTailnetDetector.isTailscaleSelfAddress(address))
}

@Test(arguments: [
    "100.63.255.255",
    "100.128.0.0",
    "99.64.0.1",
    "101.64.0.1",
    "10.64.0.1",
    "192.168.64.10",
])
func nonCGNATAddressesDoNotMatch(address: String) {
    #expect(!TailscaleTailnetDetector.isTailscaleSelfAddress(address))
}

@Test(arguments: [
    "fd7a:115c:a1e0::1",
    "fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff",
])
func tailscaleULAMembersMatch(address: String) {
    #expect(TailscaleTailnetDetector.isTailscaleSelfAddress(address))
}

@Test(arguments: [
    "fd7a:115c:a1e1::1",
    "fd7b:115c:a1e0::1",
    "fe80::1",
    "::1",
    "2001:db8::1",
])
func nonTailscaleIPv6AddressesDoNotMatch(address: String) {
    #expect(!TailscaleTailnetDetector.isTailscaleSelfAddress(address))
}

@Test(arguments: ["", "not-an-address", "100.64", "100.64.0.0.0", "%utun3"])
func unparseableAddressesDoNotMatch(address: String) {
    #expect(!TailscaleTailnetDetector.isTailscaleSelfAddress(address))
}

@Test func tunnelInterfaceFilterMatchesOnlyUtun() {
    #expect(TailscaleTailnetDetector.isTunnelInterfaceName("utun0"))
    #expect(TailscaleTailnetDetector.isTunnelInterfaceName("utun12"))
    #expect(!TailscaleTailnetDetector.isTunnelInterfaceName("en0"))
    #expect(!TailscaleTailnetDetector.isTunnelInterfaceName("pdp_ip0"))
    #expect(!TailscaleTailnetDetector.isTunnelInterfaceName("lo0"))
    #expect(!TailscaleTailnetDetector.isTunnelInterfaceName("ipsec0"))
}

// MARK: - Monitor over an injected provider

private final class FakeInterfaceProvider: NetworkInterfaceAddressProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: [NetworkInterfaceAddress]?

    init(_ snapshot: [NetworkInterfaceAddress]?) {
        self.snapshot = snapshot
    }

    func set(_ snapshot: [NetworkInterfaceAddress]?) {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
    }

    func currentInterfaceAddresses() -> [NetworkInterfaceAddress]? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

@MainActor
@Test func monitorEvaluatesSynchronouslyAtInitAndOnRefresh() {
    let provider = FakeInterfaceProvider([interface("utun5", "100.99.1.2")])
    let monitor = TailscaleStatusMonitor(provider: provider, monitorsPathChanges: false)
    #expect(monitor.status == .active)

    provider.set([interface("en0", "192.168.1.5")])
    monitor.refresh()
    #expect(monitor.status == .inactiveOrNotInstalled)

    provider.set(nil)
    monitor.refresh()
    #expect(monitor.status == .unknown)
}

// MARK: - System provider smoke

@Test func systemProviderEnumeratesInterfaces() {
    // Every Mac/iOS host has at least loopback; we only assert the walk
    // succeeds and yields parseable entries, not any specific interface.
    let snapshot = SystemNetworkInterfaceAddressProvider().currentInterfaceAddresses()
    #expect(snapshot != nil)
    #expect(!(snapshot ?? []).isEmpty)
    #expect((snapshot ?? []).allSatisfy { !$0.interfaceName.isEmpty && !$0.address.isEmpty })
}
