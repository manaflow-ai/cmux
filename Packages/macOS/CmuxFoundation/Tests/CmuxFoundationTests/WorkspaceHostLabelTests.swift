import Testing
@testable import CmuxFoundation

@Suite("Workspace host labels")
struct WorkspaceHostLabelTests {
    @Test("labels user@host by its host")
    func userAtHost() throws {
        let label = try #require(WorkspaceHostLabel.ssh(destination: "leo@big-red"))
        #expect(label.kind == .ssh)
        #expect(label.label == "big-red")
        #expect(label.detail == "leo@big-red")
        #expect(label.groupingKey == "ssh:big-red")
        #expect(label.isRemote)
    }

    @Test("labels a bare host or ssh_config alias as typed, without resolving it")
    func bareHostAndAlias() throws {
        let label = try #require(WorkspaceHostLabel.ssh(destination: "  big-red \n"))
        #expect(label.label == "big-red")
        #expect(label.detail == "big-red")

        let fqdn = try #require(WorkspaceHostLabel.ssh(destination: "dev.example.com"))
        #expect(fqdn.label == "dev.example.com")
    }

    @Test("parses ssh:// URIs with user and port")
    func sshURI() throws {
        let label = try #require(WorkspaceHostLabel.ssh(destination: "ssh://leo@Big-Red:2222"))
        #expect(label.label == "Big-Red")
        #expect(label.detail == "leo@Big-Red:2222")
        #expect(label.groupingKey == "ssh:big-red:2222")

        let withPath = try #require(WorkspaceHostLabel.ssh(destination: "ssh://host/ignored"))
        #expect(withPath.label == "host")
    }

    @Test("an explicit port wins over the URI port")
    func explicitPort() throws {
        let label = try #require(WorkspaceHostLabel.ssh(destination: "ssh://host:2222", port: 22))
        #expect(label.detail == "host:22")

        let bare = try #require(WorkspaceHostLabel.ssh(destination: "leo@host", port: 2200))
        #expect(bare.label == "host")
        #expect(bare.detail == "leo@host:2200")
        #expect(bare.groupingKey == "ssh:host:2200")
    }

    @Test("handles IPv6 with and without brackets")
    func ipv6() throws {
        let bracketed = try #require(WorkspaceHostLabel.ssh(destination: "leo@[fe80::1]"))
        #expect(bracketed.label == "fe80::1")
        #expect(bracketed.detail == "leo@[fe80::1]")

        let uri = try #require(WorkspaceHostLabel.ssh(destination: "ssh://root@[2001:db8::2]:2222"))
        #expect(uri.label == "2001:db8::2")
        #expect(uri.detail == "root@[2001:db8::2]:2222")
        #expect(uri.groupingKey == "ssh:[2001:db8::2]:2222")

        let bare = try #require(WorkspaceHostLabel.ssh(destination: "2001:db8::3"))
        #expect(bare.label == "2001:db8::3")

        let ipv4 = try #require(WorkspaceHostLabel.ssh(destination: "pi@10.0.0.5"))
        #expect(ipv4.label == "10.0.0.5")
    }

    @Test("splits user and host at the last @")
    func lastAtSign() throws {
        let label = try #require(WorkspaceHostLabel.ssh(destination: "me@corp.com@jump"))
        #expect(label.label == "jump")
        #expect(label.detail == "me@corp.com@jump")
    }

    @Test("groups the same host across users, and keeps a bare host:port as typed")
    func groupingIgnoresUser() throws {
        let a = try #require(WorkspaceHostLabel.ssh(destination: "leo@big-red"))
        let b = try #require(WorkspaceHostLabel.ssh(destination: "root@BIG-RED"))
        #expect(a.groupingKey == b.groupingKey)

        let hostColon = try #require(WorkspaceHostLabel.ssh(destination: "host:2222"))
        #expect(hostColon.label == "host:2222")
        #expect(hostColon.detail == "host:2222")
        #expect(hostColon.groupingKey == "ssh:host:2222")
    }

    @Test("rejects destinations without a host", arguments: ["", "   ", "leo@", "ssh://", "[::1"])
    func rejectsEmptyHost(_ destination: String) {
        #expect(WorkspaceHostLabel.ssh(destination: destination) == nil)
    }

    @Test("labels a Cloud machine by name, falling back to its id")
    func cloudMachine() throws {
        let named = try #require(WorkspaceHostLabel.cloud(machineID: "vm_123", machineName: " my-vm "))
        #expect(named.kind == .cloud)
        #expect(named.label == "my-vm")
        #expect(named.detail == "my-vm (vm_123)")
        #expect(named.groupingKey == "cloud:vm_123")

        let unnamed = try #require(WorkspaceHostLabel.cloud(machineID: "vm_123", machineName: ""))
        #expect(unnamed.label == "vm_123")
        #expect(unnamed.detail == "vm_123")
        #expect(unnamed.groupingKey == named.groupingKey)

        #expect(WorkspaceHostLabel.cloud(machineID: " ", machineName: "x") == nil)
    }

    @Test("local workspaces carry no label")
    func local() {
        #expect(WorkspaceHostLabel.local.kind == .local)
        #expect(WorkspaceHostLabel.local.label.isEmpty)
        #expect(!WorkspaceHostLabel.local.isRemote)
        #expect(WorkspaceHostLabel.local.windowTitle(appendingTo: "build") == "build")
    }

    @Test("appends the host to window titles unless the title already names it")
    func windowTitle() throws {
        let host = try #require(WorkspaceHostLabel.ssh(destination: "leo@big-red"))
        #expect(host.windowTitle(appendingTo: "build") == "build · big-red")
        #expect(host.windowTitle(appendingTo: "  ") == "big-red")
        #expect(host.windowTitle(appendingTo: "build @big-red") == "build @big-red")
        #expect(host.windowTitle(appendingTo: " build @big-red ") == "build @big-red")
        #expect(host.windowTitle(appendingTo: "Big-Red logs") == "Big-Red logs")
        #expect(host.windowTitle(appendingTo: "big-redis") == "big-redis · big-red")
        #expect(host.windowTitle(appendingTo: "not-big-red") == "not-big-red · big-red")
    }
}
