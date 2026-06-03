import Foundation
import Testing

@testable import CmuxTerminalCore

@Suite struct TerminalServerCatalogTests {
    private func discoveredHost(
        stableID: String,
        name: String,
        hostname: String,
        serverID: String? = nil
    ) -> TerminalHost {
        TerminalHost(
            stableID: stableID,
            name: name,
            hostname: hostname,
            username: "cmux",
            symbolName: "server.rack",
            palette: .mint,
            source: .discovered,
            serverID: serverID
        )
    }

    @Test func decodesHostsFromMetadataJSON() throws {
        let json = """
        {
          "cmux": {
            "servers": [
              {
                "id": "srv-1",
                "name": "Builder",
                "hostname": "builder.local",
                "port": 2222,
                "username": "ci",
                "symbolName": "hammer",
                "palette": "amber",
                "transport": "cmuxd-remote",
                "bootstrapCommand": "tmux",
                "ssh_fallback": false,
                "direct_tls_pins": ["pin-a", "pin-a", " pin-b "]
              }
            ]
          }
        }
        """
        let catalog = try TerminalServerCatalog(metadataJSON: json, teamID: "team-9")
        let host = try #require(catalog.hosts.first)
        #expect(catalog.hosts.count == 1)
        #expect(host.stableID == "srv-1")
        #expect(host.serverID == "srv-1")
        #expect(host.teamID == "team-9")
        #expect(host.port == 2222)
        #expect(host.transportPreference == .remoteDaemon)
        #expect(host.allowsSSHFallback == false)
        #expect(host.source == .discovered)
        // Pins are normalized: trimmed and de-duplicated.
        #expect(host.directTLSPins == ["pin-a", "pin-b"])
    }

    @Test func mergeAddsBrandNewDiscoveredHosts() {
        let discovered = [discoveredHost(stableID: "a", name: "A", hostname: "a.local")]
        let merged = TerminalServerCatalog.merge(discovered: discovered, local: [])
        #expect(merged.count == 1)
        #expect(merged[0].stableID == "a")
        #expect(merged[0].source == .discovered)
    }

    @Test func mergePreservesLocalEditsOnStableIDMatch() {
        let existing = TerminalHost(
            stableID: "a",
            name: "Old Name",
            hostname: "old.local",
            username: "cmux",
            symbolName: "server.rack",
            palette: .mint,
            trustedHostKey: "trusted-key",
            sortIndex: 7,
            source: .discovered,
            sshAuthenticationMethod: .privateKey
        )
        let discovered = discoveredHost(stableID: "a", name: "New Name", hostname: "new.local")
        let merged = TerminalServerCatalog.merge(discovered: [discovered], local: [existing])
        let host = merged[0]
        // Identity-stable fields come from discovery; user-set fields carry over from local.
        #expect(host.id == existing.id)
        #expect(host.name == "New Name")
        #expect(host.hostname == "new.local")
        #expect(host.sortIndex == 7)
        #expect(host.trustedHostKey == "trusted-key")
        #expect(host.sshAuthenticationMethod == .privateKey)
    }

    @Test func mergeRetainsConfiguredCustomHosts() {
        let custom = TerminalHost(
            stableID: "custom-1",
            name: "My Box",
            hostname: "mybox.local",
            username: "me",
            symbolName: "desktopcomputer",
            palette: .rose,
            source: .custom
        )
        let discovered = discoveredHost(stableID: "disc-1", name: "Disc", hostname: "disc.local")
        let merged = TerminalServerCatalog.merge(discovered: [discovered], local: [custom])
        #expect(merged.contains { $0.stableID == "custom-1" })
        #expect(merged.contains { $0.stableID == "disc-1" })
        #expect(merged.count == 2)
    }

    @Test func mergeShadowsUnconfiguredCustomPlaceholder() {
        // An unconfigured custom placeholder that shares a name with a discovered host
        // should be dropped in favor of the discovered host.
        let placeholder = TerminalHost(
            stableID: "placeholder",
            name: "Builder",
            hostname: "",
            username: "",
            symbolName: "server.rack",
            palette: .sky,
            source: .custom
        )
        let discovered = discoveredHost(stableID: "disc", name: "Builder", hostname: "builder.local")
        let merged = TerminalServerCatalog.merge(discovered: [discovered], local: [placeholder])
        #expect(merged.count == 1)
        #expect(merged[0].stableID == "disc")
    }

    @Test func mergeSortsBySortIndexThenName() {
        let local = [
            TerminalHost(
                stableID: "z",
                name: "Zeta",
                hostname: "z.local",
                username: "u",
                symbolName: "server.rack",
                palette: .mint,
                sortIndex: 0,
                source: .custom
            ),
            TerminalHost(
                stableID: "a",
                name: "Alpha",
                hostname: "a.local",
                username: "u",
                symbolName: "server.rack",
                palette: .mint,
                sortIndex: 0,
                source: .custom
            ),
        ]
        let merged = TerminalServerCatalog.merge(discovered: [], local: local)
        #expect(merged.map(\.name) == ["Alpha", "Zeta"])
    }

    @Test func representsSameMachineMatchesByHostnameWhenIDsDiffer() {
        let lhs = discoveredHost(stableID: "x", name: "X", hostname: "shared.local")
        let rhs = discoveredHost(stableID: "y", name: "Y", hostname: "SHARED.local")
        #expect(TerminalServerCatalog.representsSameMachine(lhs, rhs))
    }

    @Test func representsSameMachineFalseForDistinctMachines() {
        let lhs = discoveredHost(stableID: "x", name: "X", hostname: "x.local")
        let rhs = discoveredHost(stableID: "y", name: "Y", hostname: "y.local")
        #expect(!TerminalServerCatalog.representsSameMachine(lhs, rhs))
    }
}
