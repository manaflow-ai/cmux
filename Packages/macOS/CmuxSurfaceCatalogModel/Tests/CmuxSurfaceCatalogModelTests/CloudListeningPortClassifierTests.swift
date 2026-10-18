import Testing
@testable import CmuxSurfaceCatalogModel

@Suite struct CloudListeningPortClassifierTests {
    /// What `ss -ltnp` prints on a desktop Cloud machine with one dev server running.
    static let desktopMachineListing = """
        State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
        LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=310,fd=14))
        LISTEN 0      128          0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=402,fd=3))
        LISTEN 0      4096               *:1337             *:*     users:(("cmux-tui",pid=512,fd=9))
        LISTEN 0      5            0.0.0.0:5901       0.0.0.0:*     users:(("Xtigervnc",pid=640,fd=7))
        LISTEN 0      100          0.0.0.0:6901       0.0.0.0:*     users:(("websockify",pid=641,fd=3))
        LISTEN 0      4096       127.0.0.1:41235      0.0.0.0:*     users:(("cmuxd-remote",pid=700,fd=11))
        LISTEN 0      511          0.0.0.0:3000       0.0.0.0:*     users:(("node",pid=2000,fd=21),("node",pid=2001,fd=21))
        LISTEN 0      511             [::]:3000          [::]:*     users:(("node",pid=2000,fd=22))
        """

    @Test("A desktop machine's system listeners are classified apart from the dev server")
    func desktopMachine() throws {
        let ports = try #require(CloudListeningPort.inventory(socketListing: Self.desktopMachineListing))
        #expect(ports.map(\.port) == [22, 53, 1337, 3000, 5901, 6901, 41235])
        #expect(ports.filter { !$0.isSystem }.map(\.port) == [3000])
        let kinds = Dictionary(uniqueKeysWithValues: ports.map { ($0.port, $0.kind) })
        #expect(kinds[22] == .ssh)
        #expect(kinds[53] == .dns)
        #expect(kinds[1337] == .cmux)
        #expect(kinds[5901] == .desktop)
        #expect(kinds[6901] == .desktop)
        #expect(kinds[41235] == .cmux)
        let app = try #require(ports.first { $0.port == 3000 })
        #expect(app.processes == ["node"])
        #expect(app.pids == [2000, 2001])
        #expect(app.addresses == ["0.0.0.0", "[::]"])
        #expect(!app.isLoopbackOnly)
    }

    @Test("Unknown ownership shows a listener instead of hiding it")
    func unknownOwnerIsApp() {
        #expect(CloudListeningPortKind.classify(port: 8081, addresses: ["127.0.0.1"], processes: []) == .app)
        #expect(CloudListeningPortKind.classify(port: 33015, addresses: ["127.0.0.1"], processes: ["containerd"]) == .container)
        #expect(CloudListeningPortKind.classify(port: 33015, addresses: ["127.0.0.1"], processes: ["containerd", "node"]) == .app)
    }

    @Test("Only cmux's own processes are cmux; a user's cmux-named program is theirs")
    func cmuxProcessNames() {
        for name in ["cmux-tui", "cmuxd", "cmuxd-remote", "cmux-cloud-adapter", "cmux-cloud-adap"] {
            #expect(CloudListeningPortKind.classify(port: 41235, addresses: ["127.0.0.1"], processes: [name]) == .cmux, "\(name)")
        }
        for name in ["cmux-demo", "cmuxapp", "CMUX-TUI"] {
            #expect(CloudListeningPortKind.classify(port: 4000, addresses: ["0.0.0.0"], processes: [name]) == .app, "\(name)")
        }
    }

    @Test("Only the resolver stub's loopback addresses are DNS")
    func loopbackAliases() {
        #expect(CloudListeningPortKind.classify(port: 5355, addresses: ["127.0.0.53"], processes: []) == .dns)
        #expect(CloudListeningPortKind.classify(port: 5355, addresses: ["127.0.0.54"], processes: []) == .dns)
        // Another 127/8 address is a service someone bound there on purpose.
        #expect(CloudListeningPortKind.classify(port: 8000, addresses: ["127.0.1.1"], processes: ["python3"]) == .app)
        #expect(CloudListeningPortKind.classify(port: 8000, addresses: ["127.0.0.2"], processes: []) == .app)
    }

    @Test("Fixed system ports stay hidden whatever the owner")
    func fixedSystemPorts() {
        #expect(CloudListeningPortKind.classify(port: 22, addresses: ["0.0.0.0"], processes: ["node"]) == .ssh)
        #expect(CloudListeningPortKind.classify(port: 1337, addresses: ["*"], processes: []) == .cmux)
        #expect(CloudListeningPortKind.classify(port: 8080, addresses: ["0.0.0.0"], processes: []) == .image)
        #expect(CloudListeningPortKind.classify(port: 53, addresses: ["0.0.0.0"], processes: ["dnsmasq"]) == .dns)
    }

    @Test("Display slots follow the Desktop when known, the owner when not")
    func displaySlots() {
        #expect(CloudListeningPortKind.classify(port: 5901, addresses: ["0.0.0.0"], processes: [], displayPortsOwned: true) == .desktop)
        #expect(CloudListeningPortKind.classify(port: 5901, addresses: ["0.0.0.0"], processes: [], displayPortsOwned: false) == .app)
        #expect(CloudListeningPortKind.classify(port: 5901, addresses: ["0.0.0.0"], processes: [], displayPortsOwned: nil) == .desktop)
        #expect(CloudListeningPortKind.classify(port: 5901, addresses: ["0.0.0.0"], processes: ["python3"], displayPortsOwned: nil) == .app)
        #expect(CloudListeningPortKind.classify(port: 6901, addresses: ["0.0.0.0"], processes: ["websockify"], displayPortsOwned: false) == .desktop)
    }

    @Test("netstat owners are parsed like ss owners")
    func netstatOwners() throws {
        let ports = try #require(CloudListeningPort.inventory(socketListing: """
            Active Internet connections (only servers)
            Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
            tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      402/sshd
            tcp        0      0 127.0.0.1:5173          0.0.0.0:*               LISTEN      2100/node
            tcp6       0      0 :::8000                 :::*                    LISTEN      -
            """))
        #expect(ports.map(\.port) == [22, 5173, 8000])
        #expect(ports.first { $0.port == 5173 }?.processes == ["node"])
        #expect(ports.first { $0.port == 5173 }?.isLoopbackOnly == true)
        #expect(ports.first { $0.port == 8000 }?.processes == [])
        #expect(ports.first { $0.port == 8000 }?.kind == .app)
    }

    @Test("A diagnostics-only listing is a failed inventory, an empty one is not")
    func failedInventory() {
        #expect(CloudListeningPort.inventory(socketListing: "No port inspector found") == nil)
        #expect(CloudListeningPort.inventory(socketListing: "") == [])
    }

    @Test("The Ports tab scan and the CLI inventory agree on which ports are the person's")
    func scanAgreesWithInventory() throws {
        let scan = try #require(CloudPortScanResult(socketListing: Self.desktopMachineListing))
        let inventory = try #require(CloudListeningPort.inventory(socketListing: Self.desktopMachineListing, displayPortsOwned: true))
        #expect(scan.ports == inventory.filter { !$0.isSystem }.map(\.port))
    }

    @Test("Sharing reads the widest publication audience")
    func sharing() {
        #expect(CloudPortSharing(accessMode: "team") == .team)
        #expect(CloudPortSharing(accessMode: "none") == .unshared)
        #expect(CloudPortSharing.unshared.rawValue == "none")
        #expect(CloudPortSharing(accessMode: nil) == .unshared)
        #expect(CloudPortSharing(accessMode: "bogus") == .unshared)
        #expect(CloudPortSharing.widest([.personal, .public, .team]) == .public)
        #expect(CloudPortSharing.widest([]) == .unshared)
    }
}
