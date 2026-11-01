import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextRemoteLocalhost
@testable import CmuxNextRemoteLocalhostService
import CmuxNextRemoteView
import CmuxNextTestSupport
import Darwin
import Foundation
import Testing

/// Open Desktop's route (HubLoopbackOpener): a Cloud machine's localhost goes through the app's
/// WireGuard hub as SOCKS5 to the machine's private address, the way cmux-tui's `wg hub` serves
/// its links, presenting the hub's per-launch client token (RFC 1929 username/password). A
/// stand-in hub on a Unix socket checks the bytes and the token, and echoes the stream.
@Suite(.serialized)
struct CloudHubLoopbackTests {
    /// The hub names its socket; a path that does not fit a Unix socket address (`sun_path`) is
    /// refused as an unavailable tunnel, never handed to the Network framework, which traps on one
    /// (issue #28492). The open runs in an exit test's child, so a trap fails this test with its
    /// frames (``ChildCrashFrames``) and no other test.
    @Test func aHubSocketPathPastTheUnixLimitIsRefusedNotATrap() async {
        await #expect(processExitsWith: .success) {
            ChildCrashFrames.printOnFatalSignal("hub-opener-sun-path")
            let socket = "/" + String(repeating: "h", count: 200) + "/hub.sock"
            guard let opener = HubLoopbackOpener(hub: { .init(socket: socket, token: "t") }, address: "10.0.0.2") else {
                ChildCrashFrames.fail("no opener for 10.0.0.2")
            }
            do {
                _ = try await opener.openTunnel(host: "127.0.0.1", port: 8080)
                ChildCrashFrames.fail("the tunnel opened")
            } catch {
                // The guard's own refusal, before any connection: not a caught trap, not a failed connect.
                guard (error as? LoopbackTunnelFailure) == .unavailable(HubLoopbackOpener.socketPathTooLong) else {
                    ChildCrashFrames.fail("refused with \(error)")
                }
            }
        }
        ChildCrashFrames.record("hub-opener-sun-path")
    }

    /// One connection's SOCKS5 server: greeting, the token `cmux-hub-token`, then CONNECT, answered
    /// `reply`; after a success it echoes. A wrong token is answered with an auth failure.
    /// Nonisolated: this target defaults to the main actor, and its accept loop runs on its own thread.
    nonisolated final class FakeHub: @unchecked Sendable {
        let path = "/tmp/cmux-hubtest-\(UUID().uuidString.prefix(8)).sock"
        private let listener: Int32
        static let token = "cmux-hub-token"
        private let lock = NSLock()
        private var connect = Data()

        var connectRequest: Data { lock.withLock { connect } }

        init(reply: UInt8) throws {
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            listener = fd
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
            Thread.detachNewThread { [self] in
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                guard Self.read(client, 3) == Data([0x05, 0x01, 0x02]) else { return }
                Self.write(client, Data([0x05, 0x02]))
                guard Self.read(client, 2) == Data([0x01, 0x04]), Self.read(client, 4) == Data("cmux".utf8) else { return }
                let length = Self.read(client, 1)
                guard let count = length.first, Self.read(client, Int(count)) == Data(Self.token.utf8) else {
                    Self.write(client, Data([0x01, 0x01]))
                    return
                }
                Self.write(client, Data([0x01, 0x00]))
                let request = Self.read(client, 10)
                lock.withLock { connect = request }
                Self.write(client, Data([0x05, reply, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                guard reply == 0 else { return }
                var byte = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(client, &byte, byte.count)
                    guard count > 0 else { return }
                    Self.write(client, Data(byte[0..<count]))
                }
            }
        }

        deinit {
            close(listener)
            unlink(path)
        }

        private static func read(_ fd: Int32, _ count: Int) -> Data {
            var data = Data()
            var byte = [UInt8](repeating: 0, count: count)
            while data.count < count {
                let got = Darwin.read(fd, &byte, count - data.count)
                guard got > 0 else { break }
                data.append(contentsOf: byte[0..<got])
            }
            return data
        }

        private static func write(_ fd: Int32, _ data: Data) {
            data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, data.count) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func theMachinesLocalhostGoesToItsPrivateAddressThroughTheHub() async throws {
        let hub = try FakeHub(reply: 0x00)
        let path = hub.path
        let made = HubLoopbackOpener(hub: { .init(socket: path, token: FakeHub.token) }, address: "10.149.25.1")
        let opener = try #require(made)
        let tunnel = try await opener.openTunnel(host: "vm-test.cloud-desktop.localhost", port: 6901)
        // CONNECT, IPv4 10.149.25.1, port 6901: the machine's noVNC on its Cloud network.
        #expect(hub.connectRequest == Data([0x05, 0x01, 0x00, 0x01, 10, 149, 25, 1, 0x1A, 0xF5]))
        try await tunnel.write(Data("ping".utf8))
        var echoed = Data()
        for await event in tunnel.events {
            if case .data(let data) = event { echoed.append(data); tunnel.consumed(data.count) }
            if echoed.count >= 4 { break }
        }
        #expect(echoed == Data("ping".utf8))
        tunnel.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusalFromTheHubIsRefused() async throws {
        let hub = try FakeHub(reply: 0x05)
        let path = hub.path
        let made = HubLoopbackOpener(hub: { .init(socket: path, token: FakeHub.token) }, address: "10.149.25.1")
        let opener = try #require(made)
        await #expect(throws: LoopbackTunnelFailure.refused) { _ = try await opener.openTunnel(host: "localhost", port: 6901) }
    }

    @Test(.timeLimit(.minutes(1)))
    func aHubThatRefusesTheTokenOpensNothing() async throws {
        let hub = try FakeHub(reply: 0x00)
        let path = hub.path
        let made = HubLoopbackOpener(hub: { .init(socket: path, token: "stale-token") }, address: "10.149.25.1")
        let opener = try #require(made)
        await #expect(throws: LoopbackTunnelFailure.other("Cloud tunnel refused the handshake")) {
            _ = try await opener.openTunnel(host: "localhost", port: 6901)
        }
        #expect(hub.connectRequest.isEmpty, "no CONNECT after a refused token")
    }

    /// An Open Desktop URL names its machine in any case, and only such a URL is one: WebKit
    /// refuses exactly these, since in WebKit the page would be this Mac's own loopback.
    @Test func openDesktopURLsAreRecognizedWhateverTheirCase() throws {
        let url = try #require(RemoteLocalhostService.cloudDesktopURL(machine: "VM-Test"))
        #expect(url.host(percentEncoded: false) == "vm-test.cloud-desktop.localhost")
        #expect(BrowserNavigationGuard.isCloudDesktop(url))
        let shouted = try #require(URL(string: "http://VM-TEST.Cloud-Desktop.LOCALHOST:6901/"))
        #expect(BrowserNavigationGuard.isCloudDesktop(shouted))
        #expect(RemoteLocalhostService.desktopMachine(url: url) == "vm-test")
        let others = ["http://localhost:6901/vnc.html", "http://cloud-desktop.localhost.example.com/", "https://example.com/"]
            .compactMap(URL.init(string:))
        #expect(others.count == 3)
        for other in others {
            #expect(!BrowserNavigationGuard.isCloudDesktop(other), "\(other)")
        }
    }

    /// Open Desktop's native viewer reads the tunnel on demand: each read returns its bytes'
    /// flow-control credit, and the stream's end reads as nil.
    @Test(.timeLimit(.minutes(1)))
    func aTunnelReaderReadsInOrderAndReturnsCredit() async throws {
        let hub = try FakeHub(reply: 0x00)
        let path = hub.path
        let made = HubLoopbackOpener(hub: { .init(socket: path, token: FakeHub.token) }, address: "10.149.25.1")
        let opener = try #require(made)
        let tunnel = try await opener.openTunnel(host: "localhost", port: 6901)
        let reader = LoopbackTunnelReader(tunnel)
        try await tunnel.write(Data("RFB 003.008\n".utf8))
        var echoed = Data()
        while echoed.count < 12, let chunk = try await reader.read() { echoed.append(chunk) }
        #expect(echoed == Data("RFB 003.008\n".utf8))
        tunnel.close()
    }

    /// Open Desktop's native viewer connects at once only in the exact tab a person's open made
    /// (#29208): another tab that shows the same record first (an agent, the CLI, a script or a
    /// restore made it) asks for Connect and takes nothing from the person's tab; the CLI's open, a
    /// remote tree, or the person's tab after it left the record asks too.
    @Test @MainActor func onlyThePersonsOwnDesktopTabConnectsAtOnce() throws {
        let pages = RemoteViewPageService()
        let url = try #require(URL(string: "cmux://remote-view?host=vm-1&target=virtual&mode=control&via=cloud"))

        // An automated tab with the same record shows up before the person's tab is made.
        #expect(pages.source(for: "agent-tab", url: url, isLocal: true) == .unconfirmed)
        pages.confirm("person-tab", url: url, scope: nil)
        #expect(pages.source(for: "agent-tab", url: url, isLocal: true) == .unconfirmed, "the same address is not the same tab")
        #expect(pages.source(for: "person-tab", url: url, isLocal: true) == .person)
        #expect(pages.source(for: "person-tab", url: url, isLocal: false) == .remoteTree)
        #expect(pages.source(for: "person-tab", url: url, isLocal: true) == .person, "reading never consumes it")

        pages.confirm("cli-tab", url: url, scope: ActionRunScope(origin: .cli, allowsViewChange: false))
        #expect(pages.source(for: "cli-tab", url: url, isLocal: true) == .unconfirmed, "the CLI is not a person")

        let other = try #require(URL(string: "cmux://remote-view?host=vm-2&target=virtual&mode=control&via=cloud"))
        #expect(pages.source(for: "person-tab", url: other, isLocal: true) == .unconfirmed, "a changed record asks again")
        pages.forget("person-tab")
        #expect(pages.source(for: "person-tab", url: url, isLocal: true) == .unconfirmed, "a closed tab keeps nothing")
    }

    /// A desktop address routes over this Mac's tunnel only for a tab of this Mac's daemon: in a
    /// remote tree's tab (a process on machine A opening machine B's desktop address) it is that
    /// machine's own loopback, never machine B through this Mac.
    @Test func onlyThisMacsTabsRouteADesktopAddressOverTheTunnel() throws {
        let url = try #require(RemoteLocalhostService.cloudDesktopURL(machine: "vm-b"))
        #expect(RemoteLocalhostService.desktopMachine(url: url, tabIsLocal: true) == "vm-b")
        #expect(RemoteLocalhostService.desktopMachine(url: url, tabIsLocal: false) == nil)
    }

    /// A desktop address no store here can show (not one machine label, a trailing dot, or a tab
    /// whose localhost is this Mac on purpose) opens blank. Chromium's guard refuses any
    /// `*.cloud-desktop.localhost` page in the ordinary store, so giving it that store again would
    /// reroute the page forever.
    @Test func aDesktopAddressThatCannotRouteOpensBlankNotAReroute() throws {
        let valid = try #require(RemoteLocalhostService.cloudDesktopURL(machine: "vm-b"))
        let unroutable = ["http://a_b.cloud-desktop.localhost/", "http://x.y.cloud-desktop.localhost/",
                          "http://vm-b.cloud-desktop.localhost./"].compactMap(URL.init(string:))
        #expect(unroutable.count == 3)
        for url in unroutable {
            #expect(BrowserNavigationGuard.isCloudDesktop(url), "Chromium's guard counts \(url)")
            #expect(RemoteLocalhostStorePlan.plan(route: .thisMac, url: url) == .blank, "\(url)")
        }
        #expect(RemoteLocalhostStorePlan.plan(route: .thisMacInstead("vm-a", .turnedOff), url: valid) == .blank)
        #expect(RemoteLocalhostStorePlan.plan(route: .machine("vm-b"), url: valid) == .derived)
        let other = try #require(URL(string: "https://example.com/"))
        #expect(RemoteLocalhostStorePlan.plan(route: .thisMac, url: other) == .profile(.exceptCloudDesktop))
    }

    /// Records what a desktop opener lets through.
    nonisolated final class RecordingOpener: LoopbackTunnelOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var opened: [String] { lock.withLock { calls } }

        func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
            lock.withLock { calls.append("\(host):\(port)") }
            throw .refused
        }
    }

    /// Open Desktop reaches only its machine's desktop host on the noVNC port: another port (any
    /// other service on the private address) or another machine's desktop host is refused before
    /// the tunnel opens.
    @Test func theDesktopOpenerPassesOnlyItsMachinesNoVNC() async {
        let base = RecordingOpener()
        let opener = CloudDesktopOpener(base: base, machine: "VM-B")
        await #expect(throws: LoopbackTunnelFailure.portNotAllowed) {
            _ = try await opener.openTunnel(host: "vm-b.cloud-desktop.localhost", port: 22)
        }
        await #expect(throws: LoopbackTunnelFailure.self) {
            _ = try await opener.openTunnel(host: "vm-c.cloud-desktop.localhost", port: 6901)
        }
        #expect(base.opened.isEmpty, "nothing refused reaches the tunnel")
        await #expect(throws: LoopbackTunnelFailure.refused) {
            _ = try await opener.openTunnel(host: "vm-b.cloud-desktop.localhost", port: 6901)
        }
        #expect(base.opened == ["vm-b.cloud-desktop.localhost:6901"])
    }

    @Test func onlyTheMachinesLocalhostGoesThroughTheHub() async throws {
        let made = HubLoopbackOpener(hub: { Issue.record("dialed the hub"); return .init(socket: "/nonexistent", token: "t") },
                                     address: "10.149.25.1")
        let opener = try #require(made)
        await #expect(throws: LoopbackTunnelFailure.self) { _ = try await opener.openTunnel(host: "example.com", port: 443) }
        let refused = HubLoopbackOpener(hub: { .init(socket: "/nonexistent", token: "t") }, address: "not-an-address")
        #expect(refused == nil)
    }
}
