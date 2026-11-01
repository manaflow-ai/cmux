import CmuxNextBridge
import CmuxNextCloud
import CmuxNextRemote
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// Fuzz finding netdrop n2 (catalog row h), app side. After a network drop longer than the
/// machine daemon's resume lease, the daemon no longer has the link client's logical session.
/// Since #30410 the `cmux-tui remote connect --headless --json` client stops redialing that
/// session: it prints a `disconnected` snapshot, then `{"event":"session-unavailable"}`, and exits.
///
/// Both app links over that client (SSH and the legacy Cloud link) must then leave the
/// reconnecting state, so the machine never reads "reconnecting" or "connecting" for ever, and
/// the daemon loop's next endpoint call must start exactly one new link (a new logical session,
/// which the daemon accepts) that comes up connected. A live link is never dialed again.
@Suite(.serialized)
struct RemoteSessionGoneLinkTests {
    /// The `remote connect` part of a stand-in `cmux-tui`. Each run counts itself in `runs`. The
    /// first run comes up, then once `drop` exists ends as the #30410 client does when the daemon
    /// refuses its session: a `disconnected` snapshot, the typed `session-unavailable` line, the
    /// local socket removed, exit 1. Every later run comes up and stays up.
    static func remoteConnect(root: URL, provider: String) -> String {
        """
          N=$(( $(cat '\(root.path)/runs' 2>/dev/null || echo 0) + 1 )); echo "$N" > '\(root.path)/runs'
          : > "$S"
          snap() { printf '{"event":"connection-snapshot","local_socket":"%s","connection":{"session_id":"s%s","generation":1,"state":"%s","lane_bindings":[],"physical_link_count":1,"transport":{"provider":"\(provider)","route":"r"}}}\\n' "$S" "$N" "$1"; }
          snap connected
          if [ "$N" = 1 ]; then
            until [ -e '\(root.path)/drop' ]; do sleep 0.05; done
            snap disconnected
            printf '{"event":"session-unavailable","local_socket":"%s"}\\n' "$S"
            rm -f "$S"
            echo 'remote connection terminated: the remote session ended: the daemon no longer has it (it expired or was closed)' >&2
            exit 1
          fi
          exec sleep 60 ;;
        """
    }

    static func runs(_ root: URL) -> Int {
        Int((try? String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    static func executable(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func mark(_ root: URL, _ name: String) {
        FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil)
    }

    /// Polls `read` until `condition` holds, or 5 s pass; returns the last value.
    static func waitFor<T>(_ read: () async -> T, _ condition: (T) -> Bool) async -> T {
        let deadline = ContinuousClock.now + .seconds(5)
        var value = await read()
        while !condition(value), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            value = await read()
        }
        return value
    }

    // MARK: SSH

    @Test func anSSHLinkWhoseSessionIsGoneEndsAndTheNextConnectStartsOneNewSession() async throws {
        let root = URL(fileURLWithPath: "/tmp/rsg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = try Self.executable(root, "ssh", "#!/bin/sh\nexec /bin/sh -s\n")
        let tui = try Self.executable(root, "cmux-tui", """
            #!/bin/sh
            case "$1" in
            remote-probe) echo '{"app":"cmux-tui","version":"0.1.0","remote_protocol":7,"os":"macos","arch":"aarch64"}' ;;
            remote)
              while [ $# -gt 0 ]; do [ "$1" = --local-socket ] && S=$2; shift; done
            \(Self.remoteConnect(root: root, provider: "ssh"))
            esac

            """)
        let host = try SSHHost(destination: SSHDestination(parsing: "drill"), remoteBinary: tui.path)
        let link = SSHMachineLink(host: host, binary: tui, paths: SSHPaths(root: root.appendingPathComponent("p")),
                                  commandLine: SSHCommandLine(sshBinary: ssh.path),
                                  environment: { ProcessInfo.processInfo.environment }, onStatus: { _ in })

        await link.handle(.connect)
        let first = try await link.socketPath()
        #expect(await link.status == .connected)

        Self.mark(root, "drop")
        // The link client exited on the typed end: the machine connects again, it does not
        // stay "reconnecting" on a session nothing can resume.
        let ended = await Self.waitFor({ await link.status }) { $0 == .connecting }
        #expect(ended == .connecting, "a link whose session is gone still reads \(ended)")
        #expect(ended.sidebarStatus(startupFailed: false, daemonConnected: false, compatibility: nil) == .connecting)
        #expect(Self.runs(root) == 1, "the app redialed before its daemon loop asked for an endpoint")

        // The daemon loop's reconnect asks for the endpoint: one new link, a new session, up.
        let second = try await link.socketPath()
        #expect(await link.status == .connected)
        #expect(second == first, "the new link serves the machine's same local socket path")
        #expect(Self.runs(root) == 2)

        // A live link is never dialed again: no redial loop.
        _ = try await link.socketPath()
        try await Task.sleep(for: .milliseconds(500))
        #expect(Self.runs(root) == 2, "the app redialed a live link")
        #expect(await link.status == .connected)
        await link.stop()
    }

    // MARK: Cloud (legacy `/api/vm` link)

    @Test func aCloudLinkWhoseSessionIsGoneEndsAndTheNextConnectStartsOneNewSession() async throws {
        let root = URL(fileURLWithPath: "/tmp/rsg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tui = try Self.executable(root, "cmux-tui", """
            #!/bin/sh
            case "$1" in
            wg)
              while [ $# -gt 0 ]; do [ "$1" = --socket ] && H=$2; shift; done
              read -r token
              cat > /dev/null
              : > "$H"
              printf '{"event":"hub-ready","socket":"%s","routes":[]}\\n' "$H"
              exec sleep 60 ;;
            remote)
              while [ $# -gt 0 ]; do [ "$1" = --local-socket ] && S=$2; shift; done
              read -r token
            \(Self.remoteConnect(root: root, provider: "cloud"))
            esac

            """)
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "http://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        let urlSession = URLSessionConfiguration.ephemeral
        urlSession.protocolClasses = [CloudLinkReconnectingTests.StandInVMAPI.self]
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { nil },
                                 session: URLSession(configuration: urlSession))
        let paths = CloudPaths(root: root.appendingPathComponent("cloud", isDirectory: true))
        let hub = CloudTunnelHub(api: api, paths: paths, binary: tui, deviceName: "cn-session-gone-test")
        let link = CloudMachineLink(machineID: "vm-gone", api: api, hub: hub, paths: paths, binary: tui,
                                    deviceName: "cn-session-gone-test")
        func sidebar() -> SidebarMachine.Status {
            SidebarMachine(id: MachineID("vm-gone"), name: "Gone VM", kind: .cloud, status: .connected)
                .redialing(link.redial.isRedialing).status
        }

        _ = try await link.socketPath()
        let firstPID = await link.pid
        #expect(sidebar() == .connected)
        #expect(await link.callerOwnsVM)

        Self.mark(root, "drop")
        // The link client exited on the typed end: the link no longer counts as running.
        let ended = await Self.waitFor({ await link.callerOwnsVM }) { !$0 }
        #expect(!ended, "a link whose session is gone still reads as running")
        #expect(Self.runs(root) == 1, "the app redialed before its daemon loop asked for an endpoint")

        // The daemon loop's reconnect asks for the endpoint: one new link, a new session, up.
        _ = try await link.socketPath()
        let secondPID = await link.pid
        #expect(secondPID != nil && secondPID != firstPID)
        #expect(Self.runs(root) == 2)
        #expect(await Self.waitFor({ sidebar() }) { $0 == .connected } == .connected,
                "the new link still reads as reconnecting")

        // A live link is never dialed again: no redial loop.
        _ = try await link.socketPath()
        try await Task.sleep(for: .milliseconds(500))
        #expect(Self.runs(root) == 2, "the app redialed a live link")
        #expect(sidebar() == .connected)
        await link.stop()
        await hub.stop()
    }
}
