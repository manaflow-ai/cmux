import CmuxNextCloud
import CmuxNextSidebar
import CmuxNextWakeups
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
                body = #"{"transport":"cmux-remote","route":"ws://10.9.0.2:1337/v1/link","session":"s","trustedCarrier":false,"invitation":{"uri":"cmux://enroll/inv_test?secret=test-secret","invitationId":"inv_test","expiresAtUnix":2000000000}}"#
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

    /// A short temp root with a stand-in `cmux-tui`: `wg hub` reports ready, and `remote connect`
    /// prints the link's snapshots: connected, reconnecting once `drop` exists, connected once
    /// `back` exists.
    struct Fixture {
        let root: URL
        let hub: CloudTunnelHub
        let link: CloudMachineLink

        init() throws {
            root = URL(fileURLWithPath: "/tmp/clr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let tui = root.appendingPathComponent("cmux-tui")
            try """
                #!/bin/sh
                case "$1" in
                wg)
                  while [ $# -gt 0 ]; do [ "$1" = --socket ] && H=$2; shift; done
                  : > "$H"
                  printf '{"event":"hub-ready","socket":"%s","routes":[]}\\n' "$H"
                  exec sleep 60 ;;
                remote)
                  while [ $# -gt 0 ]; do
                    [ "$1" = --local-socket ] && S=$2
                    [ "$1" = --invite-file ] && I=$2
                    shift
                  done
                  [ -n "$I" ] && grep -q 'cmux://enroll/inv_test' "$I" || exit 41
                  : > "$S"
                  snap() { printf '{"event":"connection-snapshot","local_socket":"%s","connection":{"session_id":"s","generation":1,"state":"%s","lane_bindings":[],"physical_link_count":1,"transport":{"provider":"cloud","route":"ws://10.9.0.2:1337/v1/link"}}}\\n' "$S" "$1"; }
                  snap connected
                  until [ -e '\(root.path)/drop' ]; do sleep 0.05; done; snap reconnecting
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
            let paths = CloudPaths(root: root.appendingPathComponent("cloud", isDirectory: true))
            hub = CloudTunnelHub(api: api, paths: paths, binary: tui, deviceName: "cn-redial-test")
            link = CloudMachineLink(machineID: "vm-redial", api: api, hub: hub, paths: paths, binary: tui, deviceName: "cn-redial-test",
                                    mainWork: taskTurnMainWork())
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
}
