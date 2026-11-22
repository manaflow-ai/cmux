@testable import CmuxNextRemote
import Foundation
import Testing

@Suite struct SSHDestinationTests {
    @Test func parsesUserHostAndPort() throws {
        let destination = try SSHDestination(parsing: "dev@build-box.local:2222")
        #expect(destination.user == "dev")
        #expect(destination.host == "build-box.local")
        #expect(destination.port == 2222)
        #expect(destination.sshArgument == "dev@build-box.local")
        #expect(destination.route == "ssh://dev@build-box.local:2222")
        #expect(destination.description == "dev@build-box.local:2222")
        #expect(destination.displayName == "build-box")
    }

    @Test func aHostAliasFromSSHConfigNeedsNoUser() throws {
        let destination = try SSHDestination(parsing: "  gpu1 ")
        #expect(destination.user == nil)
        #expect(destination.port == nil)
        #expect(destination.sshArgument == "gpu1")
        #expect(destination.route == "ssh://gpu1")
        #expect(destination.displayName == "gpu1")
    }

    @Test func acceptsSSHURLsAndBracketedIPv6() throws {
        let url = try SSHDestination(parsing: "ssh://me@example.com:22")
        #expect(url.sshArgument == "me@example.com")
        #expect(url.port == 22)
        let v6 = try SSHDestination(parsing: "root@[fd7a::10]:2200")
        #expect(v6.host == "fd7a::10")
        #expect(v6.sshArgument == "root@fd7a::10")
        #expect(v6.route == "ssh://root@[fd7a::10]:2200")
        #expect(v6.displayName == "fd7a::10")
        let ip = try SSHDestination(parsing: "10.0.0.7")
        #expect(ip.displayName == "10.0.0.7")
    }

    @Test func refusesOptionInjectionPasswordsPathsAndBadPorts() {
        #expect(throws: SSHDestinationError.empty) { try SSHDestination(parsing: "   ") }
        #expect(throws: SSHDestinationError.optionLike) { try SSHDestination(parsing: "-oProxyCommand=evil") }
        #expect(throws: SSHDestinationError.optionLike) { try SSHDestination(parsing: "-p") }
        #expect(throws: SSHDestinationError.invalidUser) { try SSHDestination(parsing: "a b@host") }
        #expect(throws: SSHDestinationError.optionLike) { try SSHDestination(parsing: "-x@host") }
        #expect(throws: SSHDestinationError.invalidHost) { try SSHDestination(parsing: "me@-oProxyCommand=x") }
        #expect(throws: SSHDestinationError.invalidHost) { try SSHDestination(parsing: "user@ho;st") }
        #expect(throws: SSHDestinationError.invalidHost) { try SSHDestination(parsing: "user@") }
        #expect(throws: SSHDestinationError.invalidPort) { try SSHDestination(parsing: "host:0") }
        #expect(throws: SSHDestinationError.invalidPort) { try SSHDestination(parsing: "host:70000") }
        #expect(throws: SSHDestinationError.invalidPort) { try SSHDestination(parsing: "host:ssh") }
        #expect(throws: SSHDestinationError.password) { try SSHDestination(parsing: "ssh://me:secret@host") }
        #expect(throws: SSHDestinationError.path) { try SSHDestination(parsing: "ssh://host/tmp") }
    }

    @Test func sessionNamesArePlainWords() throws {
        #expect(try RemoteSessionName.validate(nil) == "main")
        #expect(try RemoteSessionName.validate("  ") == "main")
        #expect(try RemoteSessionName.validate("work-2.a_b") == "work-2.a_b")
        #expect(throws: RemoteSessionName.Invalid.self) { try RemoteSessionName.validate("a b") }
        #expect(throws: RemoteSessionName.Invalid.self) { try RemoteSessionName.validate("-x") }
        #expect(throws: RemoteSessionName.Invalid.self) { try RemoteSessionName.validate("$(id)") }
    }
}

@Suite struct SSHHostTests {
    @Test func machineIDIsStableAndDistinctPerSession() throws {
        let destination = try SSHDestination(parsing: "dev@box")
        let main = try SSHHost(destination: destination)
        let other = try SSHHost(destination: destination, session: "work")
        #expect(main.machineID.hasPrefix("ssh-"))
        #expect(main.machineID == (try SSHHost(destination: destination)).machineID)
        #expect(main.machineID != other.machineID)
        #expect(main.label == "box")
        #expect(other.label == "box/work")
    }

    @Test func transportRoundTripsWithoutSecrets() throws {
        let host = try SSHHost(destination: SSHDestination(parsing: "dev@box:2022"), session: "work",
                               remoteBinary: "/opt/cmux/bin/cmux-tui", remoteStateDir: "~/.cmux-alt")
        let fields = host.transportFields
        #expect(fields["kind"] == "ssh")
        #expect(fields["destination"] == "dev@box:2022")
        #expect(fields["session"] == "work")
        #expect(fields.keys.allSatisfy { !$0.lowercased().contains("password") && !$0.lowercased().contains("key") })
        #expect(SSHHost(transportFields: fields) == host)
        #expect(SSHHost(transportFields: ["kind": "cloud", "machine": "vm-1"]) == nil)
        #expect(SSHHost(transportFields: ["kind": "ssh", "destination": "-oProxyCommand=x"]) == nil)
    }

    @Test func remoteWordsMustBeShellSafe() throws {
        let destination = try SSHDestination(parsing: "box")
        #expect(throws: SSHHost.Invalid.self) { try SSHHost(destination: destination, remoteBinary: "~/bin/cmux tui") }
        #expect(throws: SSHHost.Invalid.self) { try SSHHost(destination: destination, remoteBinary: "-x") }
        #expect(throws: SSHHost.Invalid.self) { try SSHHost(destination: destination, remoteStateDir: "$(rm -rf ~)") }
    }
}

@Suite struct SSHCommandLineTests {
    let host = try! SSHHost(destination: SSHDestination(parsing: "dev@box:2022"), session: "work")

    @Test func everySSHUsesTheSystemClientWithForwardingOffAndNoPrompts() {
        let options = SSHCommandLine.enforcedOptions
        #expect(options.contains("-oBatchMode=yes"))
        #expect(options.contains("-oForwardAgent=no"))
        #expect(options.contains("-oForwardX11=no"))
        #expect(options.contains("-oClearAllForwardings=yes"))
        #expect(options.contains("-oPermitLocalCommand=no"))
        // The user's host key policy, config file, agent, ProxyJump and
        // ControlMaster stay theirs.
        for forbidden in ["StrictHostKeyChecking", "UserKnownHostsFile", "-F", "IdentityFile", "IdentitiesOnly", "ControlMaster",
                          "ProxyJump", "ProxyCommand", "PasswordAuthentication", "sshpass"] {
            #expect(!options.contains { $0.contains(forbidden) }, "must not override \(forbidden)")
        }
    }

    @Test func scriptRunsSendAScriptToShOnStdin() {
        let argv = SSHCommandLine().script(host)
        #expect(argv.first == "/usr/bin/ssh")
        #expect(argv[1] == "-T")
        #expect(Array(argv[2..<(2 + SSHCommandLine.enforcedOptions.count)]) == SSHCommandLine.enforcedOptions)
        #expect(argv.suffix(5) == ["-p", "2022", "--", "dev@box", "sh -s"])
        #expect(!argv.contains { $0.contains("sudo") })
    }

    @Test func linkUsesCmuxTuiRemoteConnectOverSSHStdioWithoutItsOwnInstaller() {
        let args = SSHCommandLine().link(host, clientStateDir: "/state", localSocket: "/tmp/l.sock")
        #expect(Array(args.prefix(3)) == ["remote", "connect", "ssh://dev@box:2022"])
        #expect(value(args, "--session") == "work")
        #expect(value(args, "--ssh-binary") == "/usr/bin/ssh")
        #expect(value(args, "--remote-binary") == "~/.local/bin/cmux-tui")
        #expect(value(args, "--state-dir") == "/state")
        #expect(value(args, "--local-socket") == "/tmp/l.sock")
        #expect(value(args, "--lanes") == "single")
        #expect(args.contains("--no-install"))
        #expect(args.contains("--headless"))
        #expect(args.contains("--json"))
        #expect(args.contains("--exit-with-parent"))
        #expect(!args.contains("--upgrade"))
        #expect(!args.contains("--agent-hooks"))
        #expect(!args.contains("--remote-state-dir"))
        // A dead link gives up after a few tries and the app waits for an event.
        #expect(value(args, "--reconnect-attempts").flatMap(Int.init).map { $0 > 0 && $0 <= 10 } == true)
        let sshArgs = args.indices.filter { args[$0] == "--ssh-arg" }.map { args[$0 + 1] }
        #expect(sshArgs == SSHCommandLine.enforcedOptions)
    }

    @Test func linkPassesANonDefaultStateDirectory() throws {
        let alt = try SSHHost(destination: SSHDestination(parsing: "box"), remoteStateDir: "~/.cmux-alt")
        let args = SSHCommandLine().link(alt, clientStateDir: "/s", localSocket: "/l")
        #expect(value(args, "--remote-state-dir") == "~/.cmux-alt")
        #expect(args[2] == "ssh://box")
    }

    @Test func linkAttachesToAnExistingDaemonSocketOnlyWhenNamed() throws {
        let brain = try SSHHost(destination: SSHDestination(parsing: "box"), remoteMuxSocket: "~/.cmux/brains/chief/daemon/cmux.sock")
        #expect(value(SSHCommandLine().link(brain, clientStateDir: "/s", localSocket: "/l"), "--remote-mux-socket") == "~/.cmux/brains/chief/daemon/cmux.sock")
        #expect(!SSHCommandLine().link(host, clientStateDir: "/s", localSocket: "/l").contains("--remote-mux-socket"))
        #expect(throws: SSHHost.Invalid.self) { try SSHHost(destination: SSHDestination(parsing: "box"), remoteMuxSocket: "/tmp/a b") }
        // A plain SSH machine keeps its id; naming a socket makes another machine.
        let plain = try SSHHost(destination: SSHDestination(parsing: "box"))
        #expect(plain.machineID != brain.machineID)
        #expect(SSHHost(transportFields: brain.transportFields) == brain)
    }

    @Test func remotePathsKeepTildeExpansionAndQuoteTheRest() {
        #expect(RemotePath.shellWord("~/.local/bin/cmux-tui") == "\"$HOME\"/'.local/bin/cmux-tui'")
        #expect(RemotePath.shellWord("~") == "\"$HOME\"")
        #expect(RemotePath.shellWord("/opt/it's/cmux-tui") == "'/opt/it'\\''s/cmux-tui'")
    }

    private func value(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
