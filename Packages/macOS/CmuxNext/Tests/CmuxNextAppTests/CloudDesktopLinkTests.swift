@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
@testable import CmuxNextRemoteView
@testable import CmuxNextRemoteViewSessions
import Foundation
import Testing

/// Open Desktop on a Cloud machine that reports a desktop: the `cmux-rd` stream over the owner's
/// Native link (`link.dial`, service `desktop`, no token), opened watching, with Take over.
@MainActor
@Suite struct CloudDesktopLinkTests {
    private static let host = "host_0123456789abcdefghij"

    /// Records what the transport sends; `.ready` opens the path.
    nonisolated final class RecordingCarrier: RemoteRdByteCarrier, @unchecked Sendable {
        private let sent = Mutex<[Data]>([])
        var frames: [Data] { sent.withLock { $0 } }
        func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
            queue.async { events(.ready) }
        }
        func send(_ bytes: Data) { sent.withLock { $0.append(bytes) } }
        func cancel() {}
    }

    /// The JSON control payloads of the recorded `u8 type, u32 len` stream frames.
    private static func controls(_ frames: [Data]) -> [[String: Any]] {
        frames.compactMap { frame in
            guard frame.count > 5 else { return nil }
            return (try? JSONSerialization.jsonObject(with: frame.dropFirst(5))) as? [String: Any]
        }
    }

    @Test func theDialIsServiceDesktopThroughTheLinkSocket() throws {
        let dial = try #require(CloudDesktopLinkDial(host: Self.host, linkSocket: "/tmp/cmux-link-abc.sock"))
        #expect(dial.arguments == ["link", "dial", "--host", Self.host, "--service", "desktop", "--socket", "/tmp/cmux-link-abc.sock"])
        #expect(CloudDesktopLinkDial.service == "desktop")
        #expect(CloudDesktopLinkDial(host: "vm-1", linkSocket: "/tmp/s") == nil, "a link host id, never a machine id")
        #expect(CloudDesktopLinkDial(host: Self.host, linkSocket: "relative.sock") == nil)
        #expect(CloudDesktopLinkDial(host: "host_../../etc/passwd0000", linkSocket: "/tmp/s") == nil)
        let info = Data(#"{"machine":"vm-1","host":"host_0123456789abcdefghij","epoch":1,"state":"running"}"#.utf8)
        #expect(CloudDesktopLinkDial(connectInfo: info, linkSocket: "/tmp/cmux-link-abc.sock") == dial)
        #expect(CloudDesktopLinkDial(connectInfo: info, linkSocket: nil) == nil, "no running link, no dial")
    }

    @Test func theHelloCarriesNoToken() throws {
        let hello = RemoteRdHello.cloudDesktop(install: "test")
        #expect(hello.token == nil)
        #expect(hello.service == "desktop")
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any])
        #expect(json["token"] == nil)
    }

    @Test(arguments: [false, true]) func theTransportSendsATokenlessHelloAndTheMode(control: Bool) async throws {
        let carrier = RecordingCarrier()
        let transport = try #require(RemoteRdStreamTransport(carrier: carrier, hello: RemoteRdHello.cloudDesktop(install: "test"),
                                                             startKey: "k", control: control))
        transport.connect()
        let deadline = ContinuousClock.now + .seconds(5)
        while Self.controls(carrier.frames).count < 2, ContinuousClock.now < deadline { await Task.yield() }
        let sent = Self.controls(carrier.frames)
        let hello = try #require(sent.first)
        #expect(hello["t"] as? String == "hello")
        #expect(hello["service"] as? String == "desktop")
        #expect(hello["token"] == nil)
        let start = try #require(sent.dropFirst().first)
        #expect(start["t"] as? String == "start")
        #expect(start["mode"] as? String == (control ? "control" : "view"))
        transport.stop()
    }

    /// The dial runs the bundled CLI's `link dial`: here a stand-in that answers the dial line on
    /// stderr and echoes its argv as the stream.
    @Test func theDialRunsLinkDialWithServiceDesktop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cdl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("cmux-tui")
        try "#!/bin/sh\nprintf '{\"ok\":true,\"path_state\":\"tunnel\",\"relay_available\":false}\\n' >&2\nprintf '%s ' \"$@\"\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let dial = try #require(CloudDesktopLinkDial(host: Self.host, linkSocket: "/tmp/cmux-link-abc.sock"))
        let stream = try await dial.open(cli: cli)
        var bytes = Data()
        while let chunk = await stream.read() { bytes.append(chunk) }
        stream.close()
        #expect(String(decoding: bytes, as: UTF8.self) == "link dial --host \(Self.host) --service desktop --socket /tmp/cmux-link-abc.sock ")
    }

    @Test func aRefusedDialThrows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cdl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("cmux-tui")
        try "#!/bin/sh\nprintf '{\"ok\":false,\"error_code\":\"not_authorized\"}\\n' >&2\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let dial = try #require(CloudDesktopLinkDial(host: Self.host, linkSocket: "/tmp/cmux-link-abc.sock"))
        await #expect(throws: DaemonError.self) { _ = try await dial.open(cli: cli) }
    }

    @Test func openDesktopDefaultsAndGateFollowTheDesktopCapability() {
        let desktop = CloudMachine(id: "vm-1", capabilities: CloudMachine.Capabilities(exec: true, desktop: true))
        let none = CloudMachine(id: "vm-2", capabilities: CloudMachine.Capabilities(exec: true))
        let undeclared = CloudMachine(id: "vm-3")
        #expect(desktop.defaultDesktopViewer == "rd")
        #expect(none.defaultDesktopViewer == "web")
        #expect(undeclared.defaultDesktopViewer == "web", "a record with no capabilities keeps noVNC")
        #expect(desktop.allows(.desktop))
        #expect(!none.allows(.desktop), "Open Desktop is refused and hidden")
        #expect(undeclared.allows(.desktop), "an older record keeps its noVNC desktop")
        let platform = CloudMachine.Capabilities(names: ["exec", "desktop", "agent_session"])
        #expect(platform.desktop, "the app server's name list says desktop")
    }

    /// The page session opens a Cloud desktop watching; Take over makes the next session's
    /// transport in control, Hand back in view.
    @Test func takeOverRestartsTheSessionInControl() throws {
        var made: [Bool] = []
        let record = try #require(RemoteViewTabRecord(host: "vm-1", target: .virtual, mode: .view, cloudDesktop: true, cloudRd: true))
        let session = try #require(RemoteViewPageSession.make(record: record, closeTab: {}, cloudRd: { _ in
            { control in
                made.append(control)
                return RemoteRdStreamTransport(carrier: RecordingCarrier(), hello: RemoteRdHello.cloudDesktop(install: "test"),
                                               startKey: "k", control: control)
            }
        }))
        #expect(made == [false], "a Cloud desktop opens watching")
        session.resume()
        let pane = session.paneForTesting
        #expect(pane.state.modeControl == .takeOver)
        pane.selectMode(.control)
        #expect(made == [false, true])
        #expect(session.nextSessionControls)
        pane.selectMode(.view)
        #expect(made == [false, true, false])
        session.end()
    }
}
