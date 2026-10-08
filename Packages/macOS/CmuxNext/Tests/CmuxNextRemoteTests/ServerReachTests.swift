import CmuxNextRemote
import Testing

/// The `server` reach record: a paired server's Chief brain session, its
/// registry transport and the routes that dial it.
@Suite struct ServerReachTests {
    let host = "host_e641389e5f37d1e37fb5"
    let install = "inst_7dadf279a00e51dc4a1f"

    @Test func brainRouteAttachesToTheBrainsOwnDaemonOverSSH() throws {
        let route = try #require(ServerReach.brainRoute(serverName: "cmux-lawrences-Mac-mini"))
        guard case .ssh(let ssh) = route else { Issue.record("not an ssh route"); return }
        #expect(ssh.destination.description == "cmux-lawrences-mac-mini")
        #expect(ssh.session == ServerReach.brainSession)
        #expect(ssh.remoteBinary == "~/.cmux/brains/chief/bin/cmux-tui")
        #expect(ssh.remoteMuxSocket == "~/.cmux/brains/chief/daemon/cmux.sock")
        let args = SSHCommandLine().link(ssh, clientStateDir: "/s", localSocket: "/l")
        let flag = try #require(args.firstIndex(of: "--remote-mux-socket"))
        #expect(args[flag + 1] == "~/.cmux/brains/chief/daemon/cmux.sock")
        #expect(args.contains("--no-install"))
    }

    @Test func serverNamesBecomeHostNamesOrNothing() {
        #expect(ServerReach.dnsLabel("Lawrence's Mac mini") == "lawrences-mac-mini")
        #expect(ServerReach.dnsLabel("build_box.local") == "build-box.local")
        #expect(ServerReach.dnsLabel("--x--") == "x")
        #expect(ServerReach.dnsLabel("$(id);`x`") == "idx")
        #expect(ServerReach.dnsLabel("日本") == nil)
        #expect(ServerReach.brainRoute(serverName: "日本") == nil)
    }

    @Test func transportRoundTripsBothRoutesWithoutSecrets() throws {
        let ssh = try ServerReach(hostID: host, installID: install, name: "cmux-lawrence",
                                  route: #require(ServerReach.brainRoute(serverName: "cmux-lawrence")))
        let fields = ssh.transportFields
        #expect(fields["kind"] == "server")
        #expect(fields["route"] == "ssh")
        #expect(fields["host"] == host)
        #expect(fields["remote_mux_socket"] == ServerReach.brainSocket)
        #expect(ServerReach(transportFields: fields) == ssh)
        #expect(fields.keys.allSatisfy { !$0.contains("token") && !$0.contains("password") && !$0.contains("key") })
        let local = try ServerReach(hostID: host, installID: install, name: "this Mac", route: .unix("/Users/me/.cmux/brains/chief/daemon/cmux.sock"))
        #expect(ServerReach(transportFields: local.transportFields) == local)
        #expect(ssh.machineID == "server-\(host)")
        // An SSH record is never read as a server and the other way round.
        #expect(SSHHost(transportFields: fields) == nil)
        #expect(ServerReach(transportFields: ["kind": "ssh", "destination": "box"]) == nil)
    }

    @Test func refusesForeignIDsAndUnsafeRoutes() {
        #expect(throws: ServerReach.Invalid.self) { try ServerReach(hostID: "vm_1", installID: install, name: "x", route: .unix("/tmp/s")) }
        #expect(throws: ServerReach.Invalid.self) { try ServerReach(hostID: host, installID: "inst_../../x", name: "x", route: .unix("/tmp/s")) }
        #expect(throws: ServerReach.Invalid.self) { try ServerReach(hostID: host, installID: install, name: " ", route: .unix("/tmp/s")) }
        #expect(throws: ServerReach.Invalid.self) { try ServerReach(hostID: host, installID: install, name: "x", route: .unix("relative.sock")) }
        #expect(throws: ServerReach.Invalid.self) { try ServerReach(hostID: host, installID: install, name: "x", route: .unix("/tmp/../etc/s")) }
        var fields = ["kind": "server", "host": host, "install": install, "name": "x", "route": "ssh", "destination": "box",
                      "remote_mux_socket": "$(rm -rf ~)"]
        #expect(ServerReach(transportFields: fields) == nil)
        fields["remote_mux_socket"] = nil
        fields["route"] = "wireguard"
        #expect(ServerReach(transportFields: fields) == nil)
    }
}
