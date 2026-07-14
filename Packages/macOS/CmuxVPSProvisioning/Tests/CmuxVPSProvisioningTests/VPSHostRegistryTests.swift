import Foundation
import Testing
@testable import CmuxVPSProvisioning

@Suite("VPSHostRegistry")
struct VPSHostRegistryTests {
    @Test("registry round-trips entries in a temp home")
    func registryRoundTrip() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vps-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = VPSHostRegistry(homeDirectory: home)
        let host = VPSHostDescriptor(destination: "dev@vps.example", port: 2222)
        let entry = VPSRegisteredHost(
            host: host,
            installedVersion: "0.99.0",
            goOS: "linux",
            goArch: "amd64",
            addedAtUnix: 1_700_000_000
        )
        try await registry.upsert(entry)
        #expect(try await registry.entry(for: host) == entry)
        #expect(try await registry.entry(destination: "dev@vps.example", port: 2222)?.slot == "vps")
        #expect(try await registry.entry(destination: "dev@vps.example", port: nil) == nil)
        #expect(try await registry.allHosts().count == 1)
        #expect(try await registry.remove(host) == entry)
        #expect(try await registry.allHosts().isEmpty)
    }

    @Test("registry resolve recovers a saved custom port from a bare destination")
    func registryResolveByDestination() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vps-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = VPSHostRegistry(homeDirectory: home)
        let host = VPSHostDescriptor(destination: "dev@vps.example", port: 2222)
        let entry = VPSRegisteredHost(
            host: host,
            installedVersion: "0.99.0",
            goOS: "linux",
            goArch: "amd64",
            addedAtUnix: 1_700_000_000
        )
        try await registry.upsert(entry)

        // Bare destination finds the unique entry with its saved port.
        #expect(try await registry.resolve(destination: "dev@vps.example", port: nil) == entry)
        // Exact port still matches; a different explicit port never does.
        #expect(try await registry.resolve(destination: "dev@vps.example", port: 2222) == entry)
        #expect(try await registry.resolve(destination: "dev@vps.example", port: 22) == nil)

        // Ambiguity (same destination on two ports) refuses to guess.
        var second = entry
        second.host = VPSHostDescriptor(destination: "dev@vps.example", port: 2223)
        try await registry.upsert(second)
        #expect(try await registry.resolve(destination: "dev@vps.example", port: nil) == nil)
        #expect(try await registry.resolve(destination: "dev@vps.example", port: 2223) == second)
    }
}
