import CmuxNextCloud
import CmuxNextSidebar
import Foundation
import Testing

/// cx-z5oif at the Cloud link boundary (``CloudMachineLink`` over a running `cmux-tui remote
/// connect`), as cx-ojk7n for SSH: after sleep, a network drop or a Wi-Fi change the link client
/// redials while its local socket stays up, and only its later `connection-snapshot` lines say
/// so. The Cloud machine must stop reading as connected until the client reports `connected`.
@Suite(.serialized)
struct CloudLinkReconnectingTests {
    /// The `/api/vm` stand-in: a tunnel enrollment and an attach endpoint, nothing else.
    nonisolated final class StandInVMAPI: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            let body: String
            if url.path.hasSuffix("/attach-endpoint") {
                body = #"{"transport":"cmux-remote","route":"ws://10.9.0.2:1337/v1/link","session":"s","trustedCarrier":false,"vmKind":"owner","invitation":{"uri":"cmux://enroll/inv_test?secret=test-secret","invitationId":"inv_test","expiresAtUnix":2000000000}}"#
            } else if url.path.hasSuffix("/cmux-remote/approve") {
                body = #"{"approved":true,"state":"approved","deviceFingerprint":"device-test"}"#
            } else {
                body = #"{"tunnelId":"t","clientConfig":"[Interface]\n[Peer]\n","routes":[]}"#
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// A short temp root with a stand-in `cmux-tui`: `wg hub` takes its client token and config on
    /// stdin (kept as `hub-token` and `hub-stdin` for the test), and `remote connect`, which must
    /// read the same token on stdin, prints the link's snapshots: connected, reconnecting
    /// once `drop` exists, connected once `back` exists; it ends once `gone` exists before `drop`.
    /// The attach answer says the caller owns the machine.
    struct Fixture {
        let root: URL
        let hub: CloudTunnelHub
        let link: CloudMachineLink
        let cloudRoot: URL

        init() throws {
            root = URL(fileURLWithPath: "/tmp/clr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let tui = root.appendingPathComponent("cmux-tui")
            try """
                #!/bin/sh
                case "$1" in
                wg)
                  while [ $# -gt 0 ]; do
                    [ "$1" = --socket ] && H=$2
                    [ "$1" = --config ] && C=$2
                    [ "$1" = --client-token-stdin ] && T=1
                    shift
                  done
                  [ "$C" = - ] && [ -n "$T" ] || exit 40
                  read -r token || exit 43
                  printf '%s\\n' "$token" > '\(root.path)/hub-token'
                  cat > '\(root.path)/hub-stdin'
                  : > "$H"
                  printf '{"event":"hub-ready","socket":"%s","routes":[]}\\n' "$H"
                  exec sleep 60 ;;
                remote)
                  while [ $# -gt 0 ]; do
                    [ "$1" = --local-socket ] && S=$2
                    [ "$1" = --invite-file ] && I=$2
                    [ "$1" = --wireguard-hub-token-stdin ] && T=1
                    shift
                  done
                  [ -n "$I" ] && grep -q 'cmux://enroll/inv_test' "$I" || exit 41
                  [ -n "$T" ] && read -r token && [ "$token" = "$(cat '\(root.path)/hub-token')" ] || exit 42
                  : > "$S"
                  snap() { printf '{"event":"connection-snapshot","local_socket":"%s","connection":{"session_id":"s","generation":1,"state":"%s","lane_bindings":[],"physical_link_count":1,"transport":{"provider":"cloud","route":"ws://10.9.0.2:1337/v1/link"}}}\\n' "$S" "$1"; }
                  snap connected
                  until [ -e '\(root.path)/drop' ]; do [ -e '\(root.path)/gone' ] && exit 0; sleep 0.05; done; snap reconnecting
                  until [ -e '\(root.path)/back' ]; do sleep 0.05; done; snap connected
                  exec sleep 60 ;;
                esac

                """.write(to: tui, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tui.path)
            let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "http://vm-api.standin.invalid"],
                                                           process: [:], isDebugBuild: true)
            let urlSession = URLSessionConfiguration.ephemeral
            urlSession.protocolClasses = [StandInVMAPI.self]
            let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { nil },
                                     session: URLSession(configuration: urlSession))
            cloudRoot = root.appendingPathComponent("cloud", isDirectory: true)
            let paths = CloudPaths(root: cloudRoot)
            hub = CloudTunnelHub(api: api, paths: paths, binary: tui, deviceName: "cn-redial-test")
            link = CloudMachineLink(machineID: "vm-redial", api: api, hub: hub, paths: paths, binary: tui, deviceName: "cn-redial-test")
        }

        func mark(_ name: String) { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil) }

        /// The machine's sidebar status while its daemon connection over the link socket stays
        /// connected, as it does for the whole outage: the socket never closes.
        func sidebar() -> SidebarMachine.Status {
            let connected = SidebarMachine(id: MachineID("vm-redial"), name: "Redial VM", kind: .cloud, status: .connected)
            return connected.redialing(link.redial.isRedialing).status
        }

        func waitFor(_ condition: (SidebarMachine.Status) -> Bool) async -> SidebarMachine.Status {
            let deadline = ContinuousClock.now + .seconds(5)
            var status = sidebar()
            while !condition(status), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                status = sidebar()
            }
            return status
        }

        /// Settings' mirror of the link's owner answer once `condition` holds, or after 5 s.
        func owns(until condition: (Bool) -> Bool) async -> Bool {
            let ownership = link.ownership
            let deadline = ContinuousClock.now + .seconds(5)
            var owns = await ownership.callerOwnsVM
            while !condition(owns), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                owns = await ownership.callerOwnsVM
            }
            return owns
        }

        func remove() async {
            await link.stop()
            await hub.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func aCloudLinkThatRedialsStopsReadingAsConnectedUntilItIsBack() async throws {
        let fixture = try Fixture()
        _ = try await fixture.link.socketPath()
        #expect(fixture.sidebar() == .connected)

        fixture.mark("drop")
        let during = await fixture.waitFor { $0 != .connected }
        #expect(during == .reconnecting, "the Cloud machine reads as connected while its link redials; the terminal just freezes")

        fixture.mark("back")
        #expect(await fixture.waitFor { $0 == .connected } == .connected)
        await fixture.remove()
    }

    /// A hub that ends and starts again gets the same client token and WireGuard key (both live
    /// for the app launch), so a link that already holds the token keeps working through the
    /// restart instead of redialing into a refusal.
    @Test func aRestartedHubKeepsTheTokenItsLinksHold() async throws {
        let fixture = try Fixture()
        let first = try await fixture.hub.endpoint()
        let firstConfig = try String(contentsOf: fixture.root.appendingPathComponent("hub-stdin"), encoding: .utf8)
        await fixture.hub.stop()
        let second = try await fixture.hub.endpoint()
        let secondConfig = try String(contentsOf: fixture.root.appendingPathComponent("hub-stdin"), encoding: .utf8)
        #expect(first.clientToken == second.clientToken)
        #expect(firstConfig == secondConfig, "the per-launch WireGuard key survives a hub restart")
        #expect(!String(describing: second).contains(second.clientToken), "a description never shows the token")
        await fixture.remove()
    }

    /// The hub's config carries this Mac's WireGuard private key: it reaches the hub on stdin and
    /// never lands in a file, and an earlier build's config file is removed. The hub's client
    /// token reaches the link on stdin (the stand-in exits 42 otherwise) and is never written.
    @Test func theHubConfigAndTokenTravelOnStdinNeverOnDisk() async throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.cloudRoot, withIntermediateDirectories: true)
        let legacy = fixture.cloudRoot.appendingPathComponent("wireguard.conf")
        try "PrivateKey = old\n".write(to: legacy, atomically: true, encoding: .utf8)
        let legacyKey = fixture.cloudRoot.appendingPathComponent("wireguard.private.key")
        let oldKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
        try (oldKey + "\n").write(to: legacyKey, atomically: true, encoding: .utf8)

        _ = try await fixture.link.socketPath()
        let hubInput = try String(contentsOf: fixture.root.appendingPathComponent("hub-stdin"), encoding: .utf8)
        let keyLine = hubInput.split(separator: "\n").first { $0.hasPrefix("PrivateKey = ") }
        let privateKey = try #require(keyLine)
        let key = String(privateKey.dropFirst("PrivateKey = ".count))
        #expect(!key.isEmpty)
        #expect(key != oldKey, "an earlier build's key file is never reused: each launch makes its own key")
        let token = try String(contentsOf: fixture.root.appendingPathComponent("hub-token"), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        #expect(token.count == 64, "a 32-byte token, hex")
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "an earlier build's config file is removed")
        #expect(!FileManager.default.fileExists(atPath: legacyKey.path), "an earlier build's key file is removed")

        let files = FileManager.default.enumerator(at: fixture.cloudRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            #expect(!text.contains("[Interface]"), "\(file.lastPathComponent) holds a WireGuard config")
            #expect(!text.contains(token), "\(file.lastPathComponent) holds the hub's client token")
            #expect(!text.contains(key), "\(file.lastPathComponent) holds the WireGuard private key")
        }
        await fixture.remove()
    }

    /// The owner answer lives only as long as its link process: Settings > Machines stops
    /// showing the VM switch when the link ends, and a start authorized on one link never
    /// counts on the next (``CloudMachineLink/ownerLink``).
    @Test func aLinkThatEndsNoLongerSaysTheCallerOwnsTheMachine() async throws {
        let fixture = try Fixture()
        _ = try await fixture.link.socketPath()
        let first = await fixture.link.ownerLink
        #expect(first != nil)
        #expect(await fixture.owns { $0 })

        fixture.mark("gone")
        #expect(await fixture.owns { !$0 } == false, "Settings keeps the VM switch after the link process ended")
        #expect(await fixture.link.ownerLink == nil)

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("gone"))
        _ = try await fixture.link.socketPath()
        let second = await fixture.link.ownerLink
        #expect(second != nil && second != first, "an owner answer carried over to the next link")
        await fixture.remove()
    }

    /// Move to Cloud's owner word names the link process it came from (`--to-pid`), so the pump
    /// sends it only over a connection that process serves: none once that link ends, and the
    /// replacement's own pid after it comes up.
    @Test func theOwnerWordNamesTheLinkProcessItCameFrom() async throws {
        let fixture = try Fixture()
        _ = try await fixture.link.socketPath()
        let first = try #require(await fixture.link.ownerPID)
        let firstPID = await fixture.link.pid
        #expect(first == firstPID)

        fixture.mark("gone")
        #expect(await fixture.owns { !$0 } == false)
        #expect(await fixture.link.ownerPID == nil, "an ended link still names a process for the owner word")

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("gone"))
        _ = try await fixture.link.socketPath()
        let second = try #require(await fixture.link.ownerPID)
        let secondPID = await fixture.link.pid
        #expect(second != first && second == secondPID)
        await fixture.remove()
    }
}
