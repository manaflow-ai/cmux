import CmuxNextServer
import Foundation
import Testing

/// New Remote Group lists the hosts a person can pick (remote-groups-DESIGN.md slice E): the
/// machines already connected, online Tailscale peers, then the `Host` aliases of `~/.ssh/config`,
/// each host once.
struct RemoteGroupHostChoicesTests {
    @Test func sshConfigAliasesSkipPatternsCommentsAndMatchBlocks() {
        let text = """
        # fleet
        Host mini cmux-mini
          HostName 100.1.2.3
        Host *.internal !bad
        host=box\tlinux-vm
        Host *
          ServerAliveInterval 30
        Match host foo
        Host Mini
        Include ~/.ssh/cloud-mac/config other.d/*
        """
        let config = SSHConfigHosts(text: text)
        #expect(config.aliases == ["mini", "cmux-mini", "box", "linux-vm"])
        #expect(config.includes == ["~/.ssh/cloud-mac/config", "other.d/*"])
    }

    @Test func connectedHostsComeFirstThenOnlinePeersThenAliasesEachOnce() {
        let peers = [
            HostCandidate(name: "studio", dnsName: "studio.tail1234.ts.net.", ip: "100.2.2.2", os: "macOS", online: true, alreadyPeer: false),
            HostCandidate(name: "old-box", dnsName: "old-box.tail1234.ts.net.", ip: "100.3.3.3", os: "linux", online: false, alreadyPeer: false),
            HostCandidate(name: "mini", dnsName: "mini.tail1234.ts.net.", ip: "100.1.1.1", os: "macOS", online: true, alreadyPeer: false),
        ]
        let choices = RemoteHostChoice.merge(connected: ["mini"], tailnet: peers, sshAliases: ["studio", "linux-vm", "Linux-VM"])
        #expect(choices.map(\.destination) == ["mini", "studio.tail1234.ts.net", "linux-vm"])
        #expect(choices.map(\.kind) == [.connected, .tailnet, .sshAlias])
        #expect(choices.map(\.name) == ["mini", "studio", "linux-vm"])
    }

    /// The palette asks synchronously: the catalog answers from its cache and refreshes it once a minute.
    @MainActor @Test func theCatalogListsPeersAndAliasesAfterItsRefresh() async {
        let peer = HostCandidate(name: "studio", dnsName: "studio.ts.net.", ip: "100.2.2.2", os: "macOS", online: true, alreadyPeer: false)
        let catalog = RemoteHostCatalog(connected: { ["mini"] }, peers: { [peer] }, aliases: { ["linux-vm"] })
        await catalog.reload()
        #expect(catalog.choices().map(\.destination) == ["mini", "studio.ts.net", "linux-vm"])
        #expect(catalog.choices().map(\.title).allSatisfy { !$0.isEmpty })
    }

    @Test func aliasesAreReadFromConfigAndItsIncludes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "config.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Include config.d/*\nHost mini\n".write(to: root.appending(path: "config"), atomically: true, encoding: .utf8)
        try "Host linux-vm\n".write(to: root.appending(path: "config.d/work"), atomically: true, encoding: .utf8)
        let read = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        #expect(SSHConfigHosts.aliases(in: root, home: root, read: read) == ["mini", "linux-vm"])
        #expect(SSHConfigHosts.aliases(in: root.appending(path: "none"), home: root, read: read).isEmpty)
    }

    @Test func noHostsIsAnEmptyList() {
        #expect(RemoteHostChoice.merge(connected: [], tailnet: [], sshAliases: []).isEmpty)
    }
}
