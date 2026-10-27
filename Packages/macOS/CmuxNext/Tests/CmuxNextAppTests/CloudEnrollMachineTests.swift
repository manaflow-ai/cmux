import CmuxNextCloud
import Foundation
import Testing

/// `cmux cloud enroll-machine` (CloudMachineEnrollment): what goes onto the machine, and the ssh
/// files it keeps on this Mac, idempotent and leaving everything else in them alone.
@Suite
struct CloudEnrollMachineTests {
    static let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE37Tl/9rijUPR8Dvy6OrvbHfOcb5zbYWEs2QJqEehL2"
    static let hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILq/O0PxjwbFQGJxgSKRTQKMi0mGvrWppjRxGPGedMrp"
    static let enrollment = CloudMachineEnrollment(name: "lane-vm-1", machineID: "vm-1", address: "10.0.0.7", publicKey: key)

    @Test func onlyAPlainHostNameIsTaken() {
        for good in ["lane-vm-1", "box.cloud", "a_b"] { #expect(CloudMachineEnrollment.isHostName(good), "\(good)") }
        for bad in ["", "-oProxyCommand=x", "a b", "a;b", "lane/vm", "ünï", String(repeating: "a", count: 65)] {
            #expect(!CloudMachineEnrollment.isHostName(bad), "\(bad)")
        }
    }

    @Test func onlyOneEd25519KeyIsTaken() {
        #expect(CloudMachineEnrollment.ed25519Key("\(Self.key) leo@mac\n") == Self.key, "the comment is dropped")
        #expect(CloudMachineEnrollment.ed25519Key("\(Self.key) Work MacBook Pro\n") == Self.key, "a comment of several words")
        #expect(CloudMachineEnrollment.ed25519Key("ssh-ed25519\t\(Self.key.dropFirst("ssh-ed25519 ".count))\tleo") == Self.key, "tabs")
        #expect(CloudMachineEnrollment.ed25519Key("ssh-rsa AAAAB3NzaC1yc2E user") == nil)
        #expect(CloudMachineEnrollment.ed25519Key("command=\"x\" \(Self.key)") == nil, "no options")
        #expect(CloudMachineEnrollment.ed25519Key("\(Self.key)\n\(Self.key)") == nil, "one key")
        #expect(CloudMachineEnrollment.ed25519Key("ssh-ed25519 AAAA") == nil, "a whole key")
    }

    @Test func anAddressIsALiteral() {
        #expect(CloudMachineEnrollment.isAddress("10.0.0.7"))
        #expect(CloudMachineEnrollment.isAddress("fd7a::7"))
        #expect(!CloudMachineEnrollment.isAddress("box.internal"))
        #expect(!CloudMachineEnrollment.isAddress("10.0.0.7; rm -rf /"))
    }

    @Test func theMachineSideAuthorizesTheKeyOnceAndPrintsTheHostKey() {
        let command = Self.enrollment.authorizeCommand, edit = Self.enrollment.keyEdit
        #expect(edit.hasPrefix("set -eu; "), "a key file it cannot append to fails the run")
        #expect(edit.contains("awk -v k='AAAAC3NzaC1lZDI1NTE5AAAAIE37Tl/9rijUPR8Dvy6OrvbHfOcb5zbYWEs2QJqEehL2'"), "a rerun matches the whole key, not a substring")
        #expect(edit.contains(#"$1 !~ /^#/"#), "a commented-out key is not an installed one")
        #expect(edit.contains(#"[ -z "$(tail -c 1 "$f")" ] || printf '\n' >> "$f""#), "a file without a final newline gets one first")
        #expect(command.contains(#"as_u env HOME="#), "the key goes to the cmux user's file whichever account the exec uses")
        #expect(edit.contains("'\(Self.key) cmux-enroll:lane-vm-1'"))
        #expect(command.hasSuffix("cat /etc/ssh/ssh_host_ed25519_key.pub"))
    }

    @Test func theHostBlockReachesTheMachineThroughTheHub() {
        let block = Self.enrollment.hostBlock(cli: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui",
                                              hubLink: "/tmp/cmux-wg-ab.sock", knownHosts: "/Users/me/.ssh/cmux-cloud/known_hosts",
                                              identityFile: "/Users/me/.ssh/id_ed25519")
        #expect(block.contains("Host lane-vm-1\n  HostName 10.0.0.7\n  User cmux\n  Port 22\n  HostKeyAlias cmux-vm-1\n"))
        #expect(block.contains("  ProxyCommand '/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui' wg dial --hub '/tmp/cmux-wg-ab.sock' %h %p"))
        #expect(block.contains("  StrictHostKeyChecking yes\n  GlobalKnownHostsFile none\n  KnownHostsCommand none\n  ControlMaster no\n  ControlPath none\n"))
        #expect(block.contains("  IdentityFile /Users/me/.ssh/id_ed25519\n  IdentitiesOnly yes\n"))
    }

    @Test func aRerunReplacesOnlyThisMachinesBlockAndHostKey() throws {
        let other = "Host other\n  HostName 1.2.3.4\n"
        let first = try Self.enrollment.upserting("# >>> cmux machine lane-vm-1 vm-1\nOLD\n# <<< cmux machine lane-vm-1\n", into: other)
        let second = try Self.enrollment.upserting("# >>> cmux machine lane-vm-1 vm-1\nNEW\n# <<< cmux machine lane-vm-1\n", into: first)
        #expect(second == other + "# >>> cmux machine lane-vm-1 vm-1\nNEW\n# <<< cmux machine lane-vm-1\n")
        let known = Self.enrollment.pinning(Self.hostKey, into: "cmux-vm-1 ssh-ed25519 OLD\ncmux-vm-2 ssh-ed25519 KEEP\n")
        #expect(known == "cmux-vm-2 ssh-ed25519 KEEP\ncmux-vm-1 \(Self.hostKey)\n")
    }

    @Test func onlyAPlainPathGoesIntoTheConfig() {
        #expect(CloudMachineEnrollment.isPlainPath("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui"))
        for bad in ["relative/key", "/a\"b", "/a$(touch x)", "/a`x`", "/a%h", "/a\nMatch exec x", "/a\tb", "/a\\b", "~/key"] {
            #expect(!CloudMachineEnrollment.isPlainPath(bad), "\(bad)")
        }
    }

    @Test func damagedMarkersAreRefusedNotGuessed() {
        let block = "# >>> cmux machine lane-vm-1 vm-1\nNEW\n# <<< cmux machine lane-vm-1\n"
        for damaged in ["# >>> cmux machine lane-vm-1 vm-1\nHost precious\n", "Host precious\n# <<< cmux machine lane-vm-1\n",
                        "# >>> cmux machine lane-vm-1 vm-1\n# >>> cmux machine lane-vm-1 vm-1\n# <<< cmux machine lane-vm-1\n"] {
            #expect(throws: CloudMachineEnrollment.MarkersDamaged.self) { try Self.enrollment.upserting(block, into: damaged) }
        }
    }

    @Test func aSymlinkedCmuxFolderIsRefused() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true), elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ssh.appendingPathComponent("cmux-cloud"), withDestinationURL: elsewhere)
        #expect(throws: CloudMachineEnrollment.PathNotPlain.self) {
            _ = try Self.enrollment.installOnThisMac(hostKey: Self.hostKey, cli: "/bin/cmux-tui", hubLink: "/tmp/hub.sock", identityFile: nil, home: home)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    static func home() throws -> (home: URL, ssh: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-\(UUID().uuidString)", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        return (home, ssh)
    }

    func install(_ home: URL) throws -> (done: [String], pending: [String]) {
        try Self.enrollment.installOnThisMac(hostKey: Self.hostKey, cli: "/bin/cmux-tui", hubLink: "/tmp/hub.sock", identityFile: nil, home: home)
    }

    @Test func withNoSSHConfigOneIsCreatedHoldingTheInclude() throws {
        let (home, ssh) = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try install(home).done == ["ssh-config", "known-hosts", "ssh-config-include"])
        let main = try String(contentsOf: ssh.appendingPathComponent("config"), encoding: .utf8)
        #expect(main.contains("Include \(ssh.appendingPathComponent("cmux-cloud/config").path)\n"))
        #expect(try install(home).done == ["ssh-config", "known-hosts"], "a rerun leaves it alone")
        let cmux = try String(contentsOf: ssh.appendingPathComponent("cmux-cloud/config"), encoding: .utf8)
        #expect(cmux.components(separatedBy: "Host lane-vm-1").count == 2, "one block after two runs")
        let mode = try FileManager.default.attributesOfItem(atPath: ssh.appendingPathComponent("cmux-cloud/known_hosts").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func anExistingSSHConfigOrSymlinkIsNeverWritten() throws {
        let (home, ssh) = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let bytes = Data([0x48, 0x6f, 0x73, 0x74, 0x20, 0x78, 0x0a, 0x23, 0xff, 0xfe, 0x0a]) // "Host x\n#", then not UTF-8
        try bytes.write(to: ssh.appendingPathComponent("config"))
        #expect(try install(home).done == ["ssh-config", "known-hosts"])
        #expect(try Data(contentsOf: ssh.appendingPathComponent("config")) == bytes)
        let dotfile = home.appendingPathComponent("dotfiles-ssh-config")
        try "Host mine\n".write(to: dotfile, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: ssh.appendingPathComponent("config"))
        try FileManager.default.createSymbolicLink(at: ssh.appendingPathComponent("config"), withDestinationURL: dotfile)
        _ = try install(home)
        #expect(try String(contentsOf: dotfile, encoding: .utf8) == "Host mine\n", "the dotfile is untouched")
    }

    @Test func aNewConfigQuotesAnIncludeWithASpace() {
        #expect(CloudMachineEnrollment.newConfig(including: "/Users/first last/.ssh/cmux-cloud/config").hasSuffix("Include \"/Users/first last/.ssh/cmux-cloud/config\"\n"))
    }

    @Test func theRouteIsLiveOnlyWhenSSHResolvesNameToIt() {
        let ours = "user cmux\nhostname 10.0.0.7\nport 22\nhostkeyalias cmux-vm-1\nstricthostkeychecking true\nuserknownhostsfile /Users/me/.ssh/cmux-cloud/known_hosts\n"
            + "globalknownhostsfile none\ncontrolmaster false\n"
            + "proxycommand '/bin/cmux-tui' wg dial --hub '/tmp/hub.sock' %h %p\n"
        let live = { (text: String) in Self.enrollment.routeIsLive(text, cli: "/bin/cmux-tui", hubLink: "/tmp/hub.sock", knownHosts: "/Users/me/.ssh/cmux-cloud/known_hosts") }
        #expect(live(ours))
        #expect(!live("user leo\nhostname lane-vm-1\n"), "no include: ssh would dial the name itself")
        #expect(!live(ours.replacingOccurrences(of: "10.0.0.7", with: "10.9.9.9")), "an earlier Host lane-vm-1 elsewhere wins")
        #expect(!live(ours.replacingOccurrences(of: "true", with: "ask")))
        #expect(!live(ours.replacingOccurrences(of: "/bin/cmux-tui", with: "/tmp/evil")), "another program's wg dial is not this route")
        #expect(!live(ours.replacingOccurrences(of: "/Users/me/", with: "/tmp/x/")), "another known_hosts is not this route")
        #expect(!live(ours.replacingOccurrences(of: "port 22", with: "port 2222")), "a Host * Port elsewhere is not this route")
        #expect(!live(ours.replacingOccurrences(of: "cmux-vm-1", with: "attacker")), "another host key alias is not this route")
        #expect(!live(ours.replacingOccurrences(of: "globalknownhostsfile none", with: "globalknownhostsfile /etc/ssh/ssh_known_hosts")), "a system known_hosts could vouch for another key")
        #expect(!live(ours + "knownhostscommand /usr/local/bin/keys %H\n"))
        #expect(!live(ours.replacingOccurrences(of: "controlmaster false", with: "controlmaster auto") + "controlpath ~/.ssh/cm-%n\n"), "a shared master of another machine could answer")
    }
}
