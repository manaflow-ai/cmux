import CmuxMobileRPC
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextMobile

/// Answers from the compat adapter decoded with the shipped iOS app's own
/// RPC decoders (CmuxMobileRPC), so a field the phone requires cannot go missing.
struct MobileCompatSessionTests {
    static let surface = "0AAC5358-0B01-4706-8CDC-641CF1B48ECE"
    static let workspace = "0B8A2F1E-5A51-4C55-9F0E-6E2F6A4F9C01"

    private func makeSession() throws -> (MobileCompatSession, FakeCompatBackend, EventRecorder) {
        let data = try FixtureLoader.data("list-workspaces-cmux-next", key: "data")
        let backend = FakeCompatBackend(tree: try JSONDecoder().decode(DaemonTree.self, from: data))
        let recorder = EventRecorder()
        let host = MobileCompatHostInfo(macDeviceID: "mac-1", instanceTag: "iosln", bundleIdentifier: "com.cmuxterm.app.debug.iosln",
                                        displayName: "Test Mac", appVersion: "0.1", appBuild: "1", daemonLaneAvailable: true)
        return (MobileCompatSession(backend: backend, host: host, emit: recorder.emit()), backend, recorder)
    }

    private func call(_ session: MobileCompatSession, _ method: String, _ params: [String: Any] = [:]) async throws
        -> (ok: Bool, result: Data, error: [String: Any]?) {
        let frame = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        let raw: Data = await session.handle(frame: frame)
        let response = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let ok = response["ok"] as? Bool ?? false
        let result = try JSONSerialization.data(withJSONObject: response["result"] ?? [:])
        return (ok, result, response["error"] as? [String: Any])
    }

    @Test func hostStatusSelectsRawBytesAndCarriesIdentity() async throws {
        let (session, _, _) = try makeSession()
        let status = try MobileHostStatusResponse.decode(try await call(session, "mobile.host.status").result)
        #expect(status.macInstanceTag == "iosln")
        #expect(status.macClientNamespace == "mac:com.cmuxterm.app.debug.iosln")
        #expect(status.capabilities.contains("terminal.bytes.v1"))
        #expect(status.capabilities.contains(MobileCompatHostInfo.daemonLaneCapability))
        #expect(!status.capabilities.contains { $0.hasPrefix("terminal.render_grid") })
        #expect(status.terminalFidelity == nil)
    }

    @Test func workspaceListDecodesWithPhoneDecoder() async throws {
        let (session, _, _) = try makeSession()
        let list = try MobileSyncWorkspaceListResponse.decode(try await call(session, "mobile.workspace.list").result)
        let row = try #require(list.workspaces.first)
        #expect(row.id == Self.workspace)
        #expect(row.title == "fx")
        #expect(row.terminals.count == 3)
        #expect(row.terminals.map(\.id).contains(Self.surface))
        #expect(row.groupID != nil)
        #expect(list.groups.first?.name == "Agents")
    }

    @Test func syncFetchFallsBackToLegacyLoop() async throws {
        let (session, _, _) = try makeSession()
        let response = try await call(session, "mobile.sync.fetch")
        #expect(!response.ok && response.error?["code"] as? String == "method_not_found")
    }

    @Test func subscribeKeepsEventsOnControlAndCoalescesTreeChanges() async throws {
        let (session, backend, recorder) = try makeSession()
        let subscribe = try MobileEventSubscribeResponse.decode(
            try await call(session, "mobile.events.subscribe", ["client_id": "phone", "stream_id": "s1",
                                                                "topics": ["workspace.updated", "terminal.bytes"]]).result)
        #expect(subscribe.streamID == "s1")
        backend.changes.signal()
        await recorder.wait(for: 1)
        backend.changes.signal()
        _ = try await call(session, "mobile.workspace.list")
        backend.changes.signal()
        await recorder.wait(for: 2)
        let topics = await recorder.frames.eventObjects.map { $0["topic"] as? String }
        #expect(topics == ["workspace.updated", "workspace.updated"])
    }

    @Test func replayReturnsDaemonSnapshotAndLiveBytesContinueAtItsSequence() async throws {
        let (session, backend, recorder) = try makeSession()
        let replay = try MobileTerminalReplayResponse.decodeForTest(try await call(session, "mobile.terminal.replay", [
            "workspace_id": Self.workspace, "surface_id": Self.surface,
            "client_id": "phone", "viewport_columns": 50, "viewport_rows": 20]).result)
        #expect(replay.surfaceID == Self.surface)
        let snapshot = try #require(replay.snapshotBase64.flatMap { Data(base64Encoded: $0) })
        #expect(String(decoding: snapshot, as: UTF8.self).contains("hello"))
        #expect(replay.sequence == 0)
        #expect(backend.attachSizes == [CellSize(cols: 50, rows: 20)])
        let channel = try #require(backend.lastChannel)
        #expect(channel.claims == 1)

        channel.push(.output(Data("ls\r\n".utf8), colors: nil))
        channel.push(.output(Data("a b".utf8), colors: nil))
        await recorder.wait(for: 2)
        let events = await recorder.frames.eventObjects
        let payloads = try events.map { try JSONSerialization.data(withJSONObject: $0["payload"] ?? [:]) }
        let first = try #require(MobileTerminalBytesEvent.decode(payloads[0]))
        let second = try #require(MobileTerminalBytesEvent.decode(payloads[1]))
        #expect(first.surfaceID == Self.surface && first.sequence == 0 && first.bytes == Data("ls\r\n".utf8))
        #expect(second.sequence == 4)

        // A second replay continues the numbering past everything sent.
        let again = try MobileTerminalReplayResponse.decodeForTest(try await call(session, "terminal.replay", [
            "workspace_id": Self.workspace, "surface_id": Self.surface]).result)
        #expect(again.sequence == 7)
    }

    @Test func inputReachesTheLocatedSurface() async throws {
        let (session, backend, _) = try makeSession()
        let response = try await call(session, "terminal.input", ["workspace_id": Self.workspace,
                                                                   "surface_id": Self.surface.lowercased(), "text": "ls\r"])
        #expect(response.ok)
        #expect(backend.sent.first?.0 == SurfaceID(6))
        #expect(backend.sent.first?.1 == Data("ls\r".utf8))
        let missing = try await call(session, "terminal.input", ["surface_id": UUID().uuidString, "text": "x"])
        #expect(!missing.ok && missing.error?["code"] as? String == "not_found")
    }

    // "window-size latest": after another client (the Mac) sized the
    // terminal, the phone's next keystroke takes geometry back, once.
    @Test func phoneInputReclaimsGeometryAfterAnotherClientSizedTheTerminal() async throws {
        let (session, backend, recorder) = try makeSession()
        _ = try await call(session, "mobile.terminal.replay", [
            "workspace_id": Self.workspace, "surface_id": Self.surface,
            "client_id": "phone", "viewport_columns": 50, "viewport_rows": 20])
        let channel = try #require(backend.lastChannel)
        #expect(channel.claims == 1)
        let input: [String: Any] = ["workspace_id": Self.workspace, "surface_id": Self.surface, "text": "x"]
        _ = try await call(session, "terminal.input", input)
        #expect(channel.claims == 1)

        channel.push(.resized(TerminalReplay(cols: 120, rows: 40, data: Data(), colors: nil)))
        await recorder.wait(for: 1)
        _ = try await call(session, "terminal.input", input)
        #expect(channel.claims == 2)
        _ = try await call(session, "terminal.input", input)
        #expect(channel.claims == 2)

        // The phone's own grid coming back keeps its claim.
        channel.push(.resized(TerminalReplay(cols: 50, rows: 20, data: Data(), colors: nil)))
        await recorder.wait(for: 2)
        _ = try await call(session, "terminal.input", input)
        #expect(channel.claims == 2)
    }

    @Test func unknownMethodsAnswerMethodNotFound() async throws {
        let (session, _, _) = try makeSession()
        for method in ["mobile.browser.list", "mobile.chat.sessions", "mobile.simulator.list"] {
            let response = try await call(session, method)
            #expect(response.error?["code"] as? String == "method_not_found", "\(method)")
        }
    }
}

extension MobileTerminalReplayResponse {
    static func decodeForTest(_ data: Data) throws -> MobileTerminalReplayResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
