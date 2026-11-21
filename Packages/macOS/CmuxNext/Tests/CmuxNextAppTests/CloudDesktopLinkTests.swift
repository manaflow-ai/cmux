@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
@testable import CmuxNextDaemonService
@testable import CmuxNextRemoteView
@testable import CmuxNextRemoteViewSessions
import CmuxNextSettings
import Foundation
import Testing

/// Open Desktop on a Cloud machine that reports a desktop: the `cmux-rd` stream over the carrier
/// (`cmux carrier dial --service desktop`, CloudCarrierDialTests; no token in the hello), opened watching, with Take over.
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

    /// A classic machine that declares a desktop (once the noVNC page's) is refused with the Cloud error before
    /// any workspace opens; so is any viewer but `rd`.
    @Test func openDesktopOnAClassicMachineFailsUpFront() throws {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-classic")
        session.machine = CloudMachine(id: "vm-classic", status: .running, displayName: "Classic VM",
                                       capabilities: CloudMachine.Capabilities(exec: true, desktop: true))
        let context = AppActionContext(services: services)
        #expect(throws: ActionFailure(message: CloudStrings.desktopUnavailable(session.machine.title))) {
            try CloudHandlers.openDesktop(session, context)
        }
        #expect(throws: ActionFailure(message: CloudStrings.desktopUnavailable(session.machine.title))) {
            try CloudHandlers.openDesktop(session, context, viewer: "web")
        }
    }

    /// The phone is never offered a Cloud desktop: it has no carrier route to one yet.
    @Test func thePhoneIsOfferedNoCloudDesktop() async {
        let services = MachineIconTests.services()
        #expect(await services.phoneCloudLinks().desktops == false)
    }

    /// Open Desktop has only the carrier viewer: a classic machine (no carrier route), or a cmux-next one
    /// that serves no desktop, is refused up front instead of opening a blank tab.
    @Test func openDesktopNeedsTheCarrierDesktop() throws {
        let desktop = CloudMachine(id: "vm-1", capabilities: CloudMachine.Capabilities(exec: true, desktop: true))
        let none = CloudMachine(id: "vm-2", capabilities: CloudMachine.Capabilities(exec: true))
        let undeclared = CloudMachine(id: "vm-3")
        #expect(!desktop.opensCarrierDesktop, "a classic machine has no carrier route")
        #expect(!undeclared.opensCarrierDesktop)
        var next = desktop
        next.provider = "cmux-next"
        #expect(!next.opensCarrierDesktop, "a declared desktop capability is not the record's `desktop`")
        next.servesDesktop = true
        #expect(next.opensCarrierDesktop)
        next.createdBy = "user_00000000000000000002"
        #expect(next.opensCarrierDesktop, "the carrier refuses a teammate (service_refused), not the app")
        #expect(desktop.allows(.desktop))
        #expect(!none.allows(.desktop), "Open Desktop is refused and hidden")
        #expect(undeclared.allows(.desktop))
        let platform = try #require(CloudMachine(next: .object(["id": .string("vm-4"), "provider_operations": .array([.string("exec"), .string("desktop"), .string("agent_session")])])))
        #expect(platform.capabilities.desktop, "the app server's name list says desktop")
    }

    /// A Cloud session's daemon connection waits out the carrier's dial of a cold machine (180 s): the
    /// handshake and the first-connect deadline get the carrier's deadline plus slack, not 30 s and 10 s.
    @Test func aCarrierConnectionWaitsOutAColdDial() async {
        #expect(CloudCarrierDial.handshakeDeadline == .seconds(182))
        let daemon = DaemonService(machineID: "cloud:vm-cold")
        daemon.start(remote: { throw CancellationError() }, handshake: CloudCarrierDial.handshakeDeadline)
        #expect(daemon.startupDeadline == .seconds(182))
        await daemon.shutdownConnectionAndWait()
        let local = DaemonService(machineID: "cloud:vm-plain")
        local.start(remote: { throw CancellationError() })
        #expect(local.startupDeadline == DaemonStartup.shared.defaultDeadline)
        await local.shutdownConnectionAndWait()
    }

    /// The page session opens a Cloud desktop watching; Take over makes the next session's
    /// transport in control, Hand back in view.
    @Test func takeOverRestartsTheSessionInControl() throws {
        var made: [Bool] = []
        let record = try #require(RemoteViewTabRecord(host: "vm-1", target: .virtual, mode: .view, cloudDesktop: true, cloudRd: true))
        let maybeSession = RemoteViewPageSession.make(record: record, closeTab: {}, cloudRd: { _ in
            { control in
                made.append(control)
                return RemoteRdStreamTransport(carrier: RecordingCarrier(), hello: RemoteRdHello.cloudDesktop(install: "test"),
                                               startKey: "k", control: control)
            }
        })
        let session = try #require(maybeSession)
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

    /// `remote_view.mode` (release builds): Take over on a Cloud desktop tab's session, as the
    /// button does; a session without Take over refuses.
    @Test func theControlSurfaceSwitchesModeOnACloudDesktop() throws {
        var made: [Bool] = []
        let record = try #require(RemoteViewTabRecord(host: "vm-1", target: .virtual, mode: .view, cloudDesktop: true, cloudRd: true))
        let maybeSession = RemoteViewPageSession.make(record: record, closeTab: {}, cloudRd: { _ in
            { control in
                made.append(control)
                return RemoteRdStreamTransport(carrier: RecordingCarrier(), hello: RemoteRdHello.cloudDesktop(install: "test"),
                                               startKey: "k", control: control)
            }
        })
        let session = try #require(maybeSession)
        session.resume()
        #expect(session.selectMode(.control))
        #expect(made == [false, true])
        #expect(session.selectMode(.control), "the mode in force changes nothing")
        #expect(made == [false, true])
        session.end()
    }

    /// Take over on a hidden tab whose session still runs in its hide grace ends that session;
    /// showing the tab again starts a new one in control instead of resuming the watching one.
    @Test func takeOverWhileHiddenEndsTheHiddenSession() throws {
        var made: [Bool] = []
        let record = try #require(RemoteViewTabRecord(host: "vm-1", target: .virtual, mode: .view, cloudDesktop: true, cloudRd: true))
        let maybeSession = RemoteViewPageSession.make(record: record, closeTab: {}, cloudRd: { _ in
            { control in
                made.append(control)
                return RemoteRdStreamTransport(carrier: RecordingCarrier(), hello: RemoteRdHello.cloudDesktop(install: "test"),
                                               startKey: "k", control: control)
            }
        })
        let session = try #require(maybeSession)
        session.resume()
        session.pause()
        #expect(session.isLiveWhileHidden)
        #expect(session.selectMode(.control))
        #expect(!session.isLiveWhileHidden, "the watching session ended")
        #expect(made == [false])
        session.resume()
        #expect(made == [false, true], "shown again: a new session, in control")
        session.end()
    }

    /// A Cloud desktop tab opens watching whatever `mode=` its record carries.
    @Test func aCloudDesktopRecordInControlStillOpensWatching() throws {
        var made: [Bool] = []
        let record = try #require(RemoteViewTabRecord(host: "vm-1", target: .virtual, mode: .control, cloudDesktop: true, cloudRd: true))
        let maybeSession = RemoteViewPageSession.make(record: record, closeTab: {}, cloudRd: { _ in
            { control in
                made.append(control)
                return RemoteRdStreamTransport(carrier: RecordingCarrier(), hello: RemoteRdHello.cloudDesktop(install: "test"),
                                               startKey: "k", control: control)
            }
        })
        let session = try #require(maybeSession)
        #expect(made == [false])
        #expect(session.paneForTesting.state.requestedMode == .view)
        #expect(!session.nextSessionControls)
        session.end()
    }

    /// The release methods (`cloudOnly`) never press Connect and never take control; Hand back
    /// goes through.
    @Test func theReleaseSurfaceRefusesConnectAndControl() async {
        let connect = await RemoteViewTabsControl.answer(["action": "connect"], cloudOnly: true)
        #expect(connect.objectValue?["error"] != nil)
        let control = await RemoteViewTabsControl.answer(["action": "mode", "tab": "t", "mode": "control"], cloudOnly: true)
        #expect(control.objectValue?["error"]?.stringValue?.contains("person") == true)
        let view = await RemoteViewTabsControl.answer(["action": "mode", "tab": "t", "mode": "view"], cloudOnly: true)
        #expect(view.objectValue?["error"]?.stringValue == "no live session on that tab")
    }

    /// A Cloud desktop tab in the release state read (`cmux app remote-views`): `id`, its record's
    /// viewer before the person presses Connect, and a live rd session's viewer, connection and
    /// who has control (the agent while watching, the person after Take over). No screen content.
    @Test func theReleaseStateNamesViewerConnectionAndControl() async throws {
        let record = try #require(RemoteViewTabRecord(host: "vm-1", target: .virtual, mode: .view, cloudDesktop: true, cloudRd: true))
        func tab(_ id: String, _ decision: RemoteViewTabDecision) -> RemoteViewPageTab {
            RemoteViewPageTab(id: BrowserTabID(rawValue: id), engine: .webkit, profile: BrowserProfileID(rawValue: UUID()),
                              url: record.url, decision: decision, closeTab: {}, connect: { _ in },
                              cloudRd: { _ in
                                  { control in
                                      RemoteRdStreamTransport(carrier: RecordingCarrier(), hello: RemoteRdHello.cloudDesktop(install: "test"),
                                                              startKey: "k", control: control)
                                  }
                              }, loginKeychain: LoginKeychain())
        }
        func row(_ id: String) async throws -> [String: CmuxNextSettings.JSONValue] {
            let answer = await RemoteViewTabsControl.answer(["action": "state", "tab": .string(id)], cloudOnly: true)
            let rows = try #require(answer.objectValue?["tabs"]?.arrayValue)
            #expect(rows.count == 1)
            return try #require(rows.first?.objectValue)
        }
        let asking = tab("tab_state_confirm", .confirm(record))
        let first = try await row("tab_state_confirm")
        #expect(first["confirm"]?.boolValue == true)
        #expect(first["viewer"]?.stringValue == "rd")
        #expect(first["connected"]?.boolValue == false)
        #expect(first["control"]?.stringValue == "agent")
        #expect(first["session"] == CmuxNextSettings.JSONValue.null)

        let watching = tab("tab_state_live", .connect(record))
        let session = try #require(watching.debugSession)
        session.resume()
        let live = try await row("tab_state_live")
        #expect(live["viewer"]?.stringValue == "rd")
        #expect(live["connected"]?.boolValue == false, "no frame path yet: connecting")
        #expect(live["session"]?.objectValue?["end_reason"] == CmuxNextSettings.JSONValue.null, "a live session has no end reason")
        #expect(live["control"]?.stringValue == "agent")
        #expect(session.selectMode(.control))
        #expect(try await row("tab_state_live")["control"]?.stringValue == "person")
        session.end()
        withExtendedLifetime(asking) {}
    }

    /// The method `cmux app remote-views` sends is one the app registers in every build.
    @Test func theCLIReadsAReleaseMethod() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("cmux-tui/crates/cmux-tui/src/cli/app.rs"), encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.contains("const REMOTE_VIEWS_METHOD: &str = ") })
        let method = try #require(line.split(separator: "\"").dropFirst().first.map(String.init))
        #expect(method == RemoteViewTabsControl.releaseMethods.first)
        #expect(RemoteViewTabsControl.releaseMethods.contains(method))
    }
}
