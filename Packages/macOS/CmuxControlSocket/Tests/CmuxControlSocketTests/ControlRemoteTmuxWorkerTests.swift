import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlRemoteTmuxReading`` for driving
/// ``ControlRemoteTmuxWorker`` without the app target or a live
/// `RemoteTmuxController`.
private actor FakeRemoteTmuxReading: ControlRemoteTmuxReading {
    nonisolated let enabled: Bool
    var sessionsResult: Result<[ControlRemoteTmuxSession], any Error> = .success([])
    var attachResult: Result<[String]?, any Error> = .success(nil)
    var mirrorResult: Result<Void, any Error> = .success(())
    var windowResult: Result<ControlRemoteTmuxAttachOutcome, any Error> = .success(.mirrored(windowID: "W"))
    var detachResult: Result<Void, any Error> = .success(())
    var snapshotResult: ControlRemoteTmuxStateSnapshot?

    private(set) var lastHost: ControlRemoteTmuxHost?
    private(set) var lastSession: String?
    private(set) var lastCreateIfMissing: Bool?
    private(set) var lastActivateWindow: Bool?

    init(enabled: Bool = true) { self.enabled = enabled }

    nonisolated func isEnabled() -> Bool { enabled }

    func listSessions(host: ControlRemoteTmuxHost) async throws -> [ControlRemoteTmuxSession] {
        lastHost = host
        return try sessionsResult.get()
    }

    func attachControlStreamWhenReady(
        host: ControlRemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool
    ) async throws -> [String]? {
        lastHost = host
        lastSession = sessionName
        lastCreateIfMissing = createIfMissing
        return try attachResult.get()
    }

    func mirrorHost(host: ControlRemoteTmuxHost) async throws {
        lastHost = host
        try mirrorResult.get()
    }

    func mirrorHostInNewWindow(
        host: ControlRemoteTmuxHost,
        activateWindow: Bool
    ) async throws -> ControlRemoteTmuxAttachOutcome {
        lastHost = host
        lastActivateWindow = activateWindow
        return try windowResult.get()
    }

    func detach(host: ControlRemoteTmuxHost, sessionName: String) async throws {
        lastHost = host
        lastSession = sessionName
        try detachResult.get()
    }

    func stateSnapshot(
        host: ControlRemoteTmuxHost,
        sessionName: String
    ) async -> ControlRemoteTmuxStateSnapshot? {
        lastHost = host
        lastSession = sessionName
        return snapshotResult
    }
}

private struct FakeError: Error, CustomStringConvertible {
    let description: String
}

private let testStrings = ControlRemoteTmuxStrings(
    disabled: "remote tmux beta is disabled",
    hostRequired: "host is required",
    sessionRequired: "session is required",
    hostAndSessionRequired: "host and session are required"
)

private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
    ControlRequest(id: .string("1"), method: method, params: params)
}

private func makeWorker(_ reading: any ControlRemoteTmuxReading) -> ControlRemoteTmuxWorker {
    ControlRemoteTmuxWorker(reading: reading, strings: testStrings)
}

@Suite struct ControlRemoteTmuxWorkerTests {
    @Test func returnsNilForNonRemoteTmuxMethod() async {
        let worker = makeWorker(FakeRemoteTmuxReading())
        #expect(await worker.handle(request("system.ping")) == nil)
    }

    @Test func everyCommandGatesOnDisabledBetaFlag() async {
        let worker = makeWorker(FakeRemoteTmuxReading(enabled: false))
        let disabled = ControlCallResult.err(
            code: "disabled",
            message: "remote tmux beta is disabled",
            data: nil
        )
        for method in [
            "remote.tmux.sessions", "remote.tmux.attach", "remote.tmux.mirror",
            "remote.tmux.window", "remote.tmux.detach", "remote.tmux.state",
        ] {
            #expect(await worker.handle(request(method, ["host": .string("h")])) == disabled)
        }
    }

    @Test func sessionsRequiresHost() async {
        let worker = makeWorker(FakeRemoteTmuxReading())
        #expect(await worker.handle(request("remote.tmux.sessions")) == .err(
            code: "invalid_params", message: "host is required", data: nil
        ))
    }

    @Test func sessionsShapesPayloadWithCreatedOnlyWhenPresent() async {
        let reading = FakeRemoteTmuxReading()
        await reading.setSessions([
            ControlRemoteTmuxSession(id: "$1", name: "main", windowCount: 2, attached: true, createdUnix: 100),
            ControlRemoteTmuxSession(id: "$2", name: "side", windowCount: 1, attached: false, createdUnix: nil),
        ])
        let worker = makeWorker(reading)
        let result = await worker.handle(request("remote.tmux.sessions", ["host": .string("box")]))
        #expect(result == .ok(.object([
            "host": .string("box"),
            "sessions": .array([
                .object([
                    "id": .string("$1"),
                    "name": .string("main"),
                    "windows": .int(2),
                    "attached": .bool(true),
                    "created": .int(100),
                ]),
                .object([
                    "id": .string("$2"),
                    "name": .string("side"),
                    "windows": .int(1),
                    "attached": .bool(false),
                ]),
            ]),
        ])))
    }

    @Test func hostParsingRejectsDashPrefixHiddenCharsAndOutOfRangePort() async {
        let reading = FakeRemoteTmuxReading()
        let worker = makeWorker(reading)
        // dash-prefixed destination
        #expect(await worker.handle(request("remote.tmux.sessions", ["host": .string("-oProxyCommand=x")]))
            == .err(code: "invalid_params", message: "host is required", data: nil))
        // hidden control character in destination
        #expect(await worker.handle(request("remote.tmux.sessions", ["host": .string("box\u{7}")]))
            == .err(code: "invalid_params", message: "host is required", data: nil))
        // out-of-range port
        #expect(await worker.handle(request("remote.tmux.sessions", [
            "host": .string("box"), "port": .int(70000),
        ])) == .err(code: "invalid_params", message: "host is required", data: nil))
        // dash-prefixed identity file
        #expect(await worker.handle(request("remote.tmux.sessions", [
            "host": .string("box"), "identity_file": .string("-i/etc/passwd"),
        ])) == .err(code: "invalid_params", message: "host is required", data: nil))
    }

    @Test func hostParsingForwardsPortAndIdentity() async {
        let reading = FakeRemoteTmuxReading()
        let worker = makeWorker(reading)
        _ = await worker.handle(request("remote.tmux.sessions", [
            "host": .string("  box  "),
            "port": .int(2222),
            "identity_file": .string("  ~/.ssh/id  "),
        ]))
        let host = await reading.lastHost
        #expect(host == ControlRemoteTmuxHost(destination: "box", port: 2222, identityFile: "~/.ssh/id"))
    }

    @Test func attachReturnsAuthRequiredArgvWhenSeamReturnsArgv() async {
        let reading = FakeRemoteTmuxReading()
        await reading.setAttach(.success(["ssh", "--", "box", "true"]))
        let worker = makeWorker(reading)
        let result = await worker.handle(request("remote.tmux.attach", [
            "host": .string("box"), "session": .string("main"), "create": .bool(true),
        ]))
        #expect(result == .ok(.object([
            "host": .string("box"),
            "session": .string("main"),
            "auth_required": .bool(true),
            "ssh_argv": .array([.string("ssh"), .string("--"), .string("box"), .string("true")]),
        ])))
        #expect(await reading.lastCreateIfMissing == true)
    }

    @Test func attachReturnsAttachedWhenSeamReturnsNil() async {
        let reading = FakeRemoteTmuxReading()
        await reading.setAttach(.success(nil))
        let worker = makeWorker(reading)
        let result = await worker.handle(request("remote.tmux.attach", [
            "host": .string("box"), "session": .string("main"),
        ]))
        #expect(result == .ok(.object([
            "host": .string("box"),
            "session": .string("main"),
            "attached": .bool(true),
        ])))
        #expect(await reading.lastCreateIfMissing == false)
    }

    @Test func attachRequiresSession() async {
        let worker = makeWorker(FakeRemoteTmuxReading())
        #expect(await worker.handle(request("remote.tmux.attach", ["host": .string("box")]))
            == .err(code: "invalid_params", message: "session is required", data: nil))
    }

    @Test func mirrorShapesPayload() async {
        let worker = makeWorker(FakeRemoteTmuxReading())
        #expect(await worker.handle(request("remote.tmux.mirror", ["host": .string("box")]))
            == .ok(.object(["host": .string("box"), "mirrored": .bool(true)])))
    }

    @Test func windowMirroredAndAuthRequiredCases() async {
        let reading = FakeRemoteTmuxReading()
        await reading.setWindow(.success(.mirrored(windowID: "ABCD")))
        let worker = makeWorker(reading)
        #expect(await worker.handle(request("remote.tmux.window", ["host": .string("box")]))
            == .ok(.object([
                "host": .string("box"),
                "mirrored": .bool(true),
                "window_id": .string("ABCD"),
            ])))
        // default activate=true
        #expect(await reading.lastActivateWindow == true)

        await reading.setWindow(.success(.authRequired(sshArgv: ["ssh", "box"])))
        #expect(await worker.handle(request("remote.tmux.window", [
            "host": .string("box"), "activate": .bool(false),
        ])) == .ok(.object([
            "host": .string("box"),
            "auth_required": .bool(true),
            "ssh_argv": .array([.string("ssh"), .string("box")]),
        ])))
        #expect(await reading.lastActivateWindow == false)
    }

    @Test func detachShapesPayloadAndRequiresHostAndSession() async {
        let worker = makeWorker(FakeRemoteTmuxReading())
        #expect(await worker.handle(request("remote.tmux.detach", ["host": .string("box")]))
            == .err(code: "invalid_params", message: "host and session are required", data: nil))
        #expect(await worker.handle(request("remote.tmux.detach", [
            "host": .string("box"), "session": .string("main"),
        ])) == .ok(.object([
            "host": .string("box"),
            "session": .string("main"),
            "detached": .bool(true),
        ])))
    }

    @Test func stateReturnsAttachedFalseWhenNoSnapshot() async {
        let worker = makeWorker(FakeRemoteTmuxReading())
        #expect(await worker.handle(request("remote.tmux.state", [
            "host": .string("box"), "session": .string("main"),
        ])) == .ok(.object([
            "host": .string("box"),
            "session": .string("main"),
            "attached": .bool(false),
        ])))
    }

    @Test func stateMapsSnapshotWithPanePrefixAndOptionalSessionId() async {
        let reading = FakeRemoteTmuxReading()
        await reading.setSnapshot(ControlRemoteTmuxStateSnapshot(
            started: true,
            enterReceived: true,
            exited: false,
            sessionId: 7,
            windowCount: 2,
            windowIDs: [1, 2],
            paneOutputByteCounts: [5: 100],
            totalOutputBytes: 100,
            recentEvents: ["e1"]
        ))
        let worker = makeWorker(reading)
        let result = await worker.handle(request("remote.tmux.state", [
            "host": .string("box"), "session": .string("main"),
        ]))
        #expect(result == .ok(.object([
            "host": .string("box"),
            "session": .string("main"),
            "attached": .bool(true),
            "started": .bool(true),
            "enter_received": .bool(true),
            "exited": .bool(false),
            "window_count": .int(2),
            "window_ids": .array([.int(1), .int(2)]),
            "total_output_bytes": .int(100),
            "pane_output_bytes": .object(["%5": .int(100)]),
            "recent_events": .array([.string("e1")]),
            "session_id": .int(7),
        ])))
    }

    @Test func thrownErrorRendersVmErrorWithDescription() async {
        let reading = FakeRemoteTmuxReading()
        await reading.setSessions(.failure(FakeError(description: "host unreachable: boom")))
        let worker = makeWorker(reading)
        #expect(await worker.handle(request("remote.tmux.sessions", ["host": .string("box")]))
            == .err(code: "vm_error", message: "host unreachable: boom", data: nil))
    }
}

// Scriptable setters kept off the synthesized actor init for readability.
extension FakeRemoteTmuxReading {
    func setSessions(_ sessions: [ControlRemoteTmuxSession]) { sessionsResult = .success(sessions) }
    func setSessions(_ result: Result<[ControlRemoteTmuxSession], any Error>) { sessionsResult = result }
    func setAttach(_ result: Result<[String]?, any Error>) { attachResult = result }
    func setWindow(_ result: Result<ControlRemoteTmuxAttachOutcome, any Error>) { windowResult = result }
    func setSnapshot(_ snapshot: ControlRemoteTmuxStateSnapshot?) { snapshotResult = snapshot }
}
