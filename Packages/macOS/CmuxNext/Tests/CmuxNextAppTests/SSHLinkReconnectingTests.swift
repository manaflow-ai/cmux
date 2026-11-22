import CmuxNextBridge
import CmuxNextRemote
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-ojk7n at the SSH link boundary (``SSHMachineLink`` over a running `cmux-tui remote connect`):
/// sleep/wake, a network drop or a Wi-Fi change leaves the link client up while it redials, and it
/// says so on stdout (`connection-snapshot` with `state: reconnecting`). The machine must stop
/// reading as connected until the client reports `connected` again, as classic's "Reconnecting".
@Suite(.serialized)
struct SSHLinkReconnectingTests {
    /// A short temp root with a stand-in `ssh` (runs the probe script here) and a stand-in
    /// `cmux-tui` that answers the probe and, as `remote connect`, prints the link's snapshots:
    /// connected, reconnecting once `drop` exists, connected once `back` exists.
    struct Fixture {
        let root: URL
        let link: SSHMachineLink

        init() throws {
            root = URL(fileURLWithPath: "/tmp/slr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ssh = try Self.script(root, "ssh", "#!/bin/sh\nexec /bin/sh -s\n")
            let tui = try Self.script(root, "cmux-tui", """
                #!/bin/sh
                case "$1" in
                remote-probe) echo '{"app":"cmux-tui","version":"0.1.0","remote_protocol":7,"os":"macos","arch":"aarch64"}' ;;
                remote)
                  while [ $# -gt 0 ]; do [ "$1" = --local-socket ] && S=$2; shift; done
                  : > "$S"
                  snap() { printf '{"event":"connection-snapshot","local_socket":"%s","connection":{"session_id":"s","generation":1,"state":"%s","lane_bindings":[],"physical_link_count":1,"transport":{"provider":"ssh","route":"ssh://drill"}}}\\n' "$S" "$1"; }
                  snap connected
                  until [ -e '\(root.path)/drop' ]; do sleep 0.05; done; snap reconnecting
                  until [ -e '\(root.path)/back' ]; do sleep 0.05; done; snap connected
                  exec sleep 60 ;;
                esac

                """)
            let host = try SSHHost(destination: SSHDestination(parsing: "drill"), remoteBinary: tui.path)
            link = SSHMachineLink(host: host, binary: tui, paths: SSHPaths(root: root.appendingPathComponent("p")),
                                  commandLine: SSHCommandLine(sshBinary: ssh.path),
                                  environment: { ProcessInfo.processInfo.environment }, onStatus: { _ in })
        }

        static func script(_ root: URL, _ name: String, _ text: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func mark(_ name: String) { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil) }

        /// The sidebar status of this machine while its daemon socket (the link client's local
        /// socket) still answers, as it does for the whole outage.
        func sidebar() async -> SidebarMachine.Status {
            (await link.status).sidebarStatus(startupFailed: false, daemonConnected: true, compatibility: nil)
        }

        func waitFor(_ condition: (SidebarMachine.Status) -> Bool) async -> SidebarMachine.Status {
            let deadline = ContinuousClock.now + .seconds(5)
            var status = await sidebar()
            while !condition(status), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                status = await sidebar()
            }
            return status
        }

        func remove() async {
            await link.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func aLinkThatRedialsStopsReadingAsConnectedUntilItIsBack() async throws {
        let fixture = try Fixture()
        await fixture.link.handle(.connect)
        _ = try await fixture.link.socketPath()
        #expect(await fixture.sidebar() == .connected)

        fixture.mark("drop")
        let during = await fixture.waitFor { $0 != .connected }
        #expect(during != .connected, "the machine reads as connected while its link redials; the terminal just freezes")

        fixture.mark("back")
        #expect(await fixture.waitFor { $0 == .connected } == .connected)
        await fixture.remove()
    }
}
