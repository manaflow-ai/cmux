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
        let command = Self.enrollment.authorizeCommand
        #expect(command.contains("grep -qF '\(Self.key)'"), "a rerun does not add the key again")
        #expect(command.contains("'\(Self.key) cmux-enroll:lane-vm-1'"))
        #expect(command.hasSuffix("cat /etc/ssh/ssh_host_ed25519_key.pub"))
    }

    @Test func theHostBlockReachesTheMachineThroughTheHub() {
        let block = Self.enrollment.hostBlock(cli: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui",
                                              hubLink: "/tmp/cmux-wg-ab.sock", knownHosts: "/Users/me/.ssh/cmux-cloud/known_hosts",
                                              identityFile: "/Users/me/.ssh/id_ed25519")
        #expect(block.contains("Host lane-vm-1\n  HostName 10.0.0.7\n  User cmux\n"))
        #expect(block.contains(#"  ProxyCommand "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui" wg dial --hub /tmp/cmux-wg-ab.sock %h %p"#))
        #expect(block.contains("  StrictHostKeyChecking yes\n"))
        #expect(block.contains("  IdentityFile /Users/me/.ssh/id_ed25519\n"))
    }

    @Test func aRerunReplacesOnlyThisMachinesBlockAndHostKey() {
        let other = "Host other\n  HostName 1.2.3.4\n"
        let first = Self.enrollment.upserting("# >>> cmux machine lane-vm-1 vm-1\nOLD\n# <<< cmux machine lane-vm-1\n", into: other)
        let second = Self.enrollment.upserting("# >>> cmux machine lane-vm-1 vm-1\nNEW\n# <<< cmux machine lane-vm-1\n", into: first)
        #expect(second == other + "# >>> cmux machine lane-vm-1 vm-1\nNEW\n# <<< cmux machine lane-vm-1\n")
        let known = Self.enrollment.pinning(Self.hostKey, into: "10.0.0.7 ssh-ed25519 OLD\n10.0.0.8 ssh-ed25519 KEEP\n")
        #expect(known == "10.0.0.8 ssh-ed25519 KEEP\n10.0.0.7 \(Self.hostKey)\n")
    }

    @Test func theIncludeGoesFirstOnce() throws {
        let config = "Host a\n  User b\n"
        let included = CloudMachineEnrollment.including("/Users/me/.ssh/cmux-cloud/config", in: config)
        #expect(included.hasSuffix(config))
        #expect(included.contains("Include /Users/me/.ssh/cmux-cloud/config\n"))
        let include = try #require(included.range(of: "Include")), host = try #require(included.range(of: "Host a"))
        #expect(include.lowerBound < host.lowerBound)
        #expect(CloudMachineEnrollment.including("/Users/me/.ssh/cmux-cloud/config", in: included) == included)
    }

    @Test func installingWritesThisMacsFilesAndKeepsTheirOtherLines() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try "Host mine\n  User me\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let run = { try Self.enrollment.installOnThisMac(hostKey: Self.hostKey, cli: "/bin/cmux-tui", hubLink: "/tmp/hub.sock", identityFile: nil, home: home) }
        let first = try run()
        #expect(first.done == ["ssh-config", "known-hosts", "ssh-config-include"])
        #expect(first.pending.isEmpty)
        let second = try run()
        #expect(second.done == ["ssh-config", "known-hosts"], "the include is there already")
        let main = try String(contentsOf: ssh.appendingPathComponent("config"), encoding: .utf8)
        #expect(main.contains("Host mine\n  User me\n"))
        let cmux = try String(contentsOf: ssh.appendingPathComponent("cmux-cloud/config"), encoding: .utf8)
        #expect(cmux.components(separatedBy: "Host lane-vm-1").count == 2, "one block after two runs")
        let mode = try FileManager.default.attributesOfItem(atPath: ssh.appendingPathComponent("cmux-cloud/known_hosts").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aSymlinkedSSHConfigIsLeftForThePerson() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let dotfile = home.appendingPathComponent("dotfiles-ssh-config")
        try "Host mine\n".write(to: dotfile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: ssh.appendingPathComponent("config"), withDestinationURL: dotfile)
        let result = try Self.enrollment.installOnThisMac(hostKey: Self.hostKey, cli: "/bin/cmux-tui", hubLink: "/tmp/hub.sock", identityFile: nil, home: home)
        #expect(result.pending.count == 1)
        #expect(try String(contentsOf: dotfile, encoding: .utf8) == "Host mine\n", "the dotfile is untouched")
    }
}
