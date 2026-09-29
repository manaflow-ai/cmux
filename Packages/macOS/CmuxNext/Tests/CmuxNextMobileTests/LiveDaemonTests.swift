import CmuxMobileRPC
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextMobile

/// The pinned hosted cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch), or
/// `CMUX_NEXT_TUI_BIN`.
enum LiveBinary {
    static let url: URL? = {
        if let override = ProcessInfo.processInfo.environment["CMUX_NEXT_TUI_BIN"],
           FileManager.default.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        guard let pin = try? String(contentsOf: root.appendingPathComponent("scripts/cmux-next/cmux-tui.pin"), encoding: .utf8),
              let commit = pin.split(separator: "\n").first(where: { $0.hasPrefix("commit=") })?.dropFirst(7) else { return nil }
        let binary = root.appendingPathComponent("cmux-tui/target/hosted/\(commit)/cmux-tui")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }()
}


/// One isolated real daemon for a test. Afterwards `shutdown-daemon
/// end_terminals` ends every terminal, detached ones included, and the test
/// fails if any terminal host (one PTY each) outlives it.
enum LiveDaemon {
    static func with(_ body: (DaemonConnection, DaemonEndpoint) async throws -> Void) async throws {
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnm-it-\(id)")
        let launcher = DaemonLauncher(
            configuration: .init(binary: try #require(LiveBinary.url), session: "cnm-it-\(id)",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { LoginEnvironment.daemonEnvironment(login: nil, base: ProcessInfo.processInfo.environment, overrides: [:]) })
        let ensured = try await launcher.ensure()
        let control = DaemonConnection(endpointProvider: launcher.endpointProvider)
        try await control.start()
        var failure: (any Error)?
        do { try await body(control, ensured.endpoint) } catch { failure = error }
        let hosts = terminalHosts(of: ensured.pid)
        // Stop reconnecting first, or the daemon's EOF starts a fresh one.
        await control.close()
        do {
            try await control.shutdownDaemon(endTerminals: true)
        } catch {
            Issue.record("shutdown-daemon end_terminals failed: \(error)")
        }
        var leaked = hosts.filter { kill($0, 0) == 0 && !isZombie($0) }
        // Host exits trail the reply by a few milliseconds.
        for _ in 0..<200 where !leaked.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
            leaked = leaked.filter { kill($0, 0) == 0 && !isZombie($0) }
        }
        #expect(leaked.isEmpty, "terminal hosts outlived shutdown-daemon end_terminals: \(leaked)")
        try? FileManager.default.removeItem(at: root)
        if let failure { throw failure }
    }

    /// The daemon's `cmux-tui __terminal-host` children (one PTY each).
    static func terminalHosts(of pid: Int32) -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid), "-f", "__terminal-host"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) })
    }

    static func isZombie(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 && info.pbi_status == UInt32(SZOMB)
    }
}

/// Compat adapter and daemon lane against a real, isolated cmux-tui daemon.
/// Every terminal is closed and the daemon shut down afterwards (terminal
/// hosts outlive the daemon and each holds a PTY).
@Suite(.enabled(if: LiveBinary.url != nil, "no cmux-tui binary"), .timeLimit(.minutes(2)), .serialized)
struct LiveDaemonTests {
    private func call(_ session: MobileCompatSession, _ method: String, _ params: [String: Any] = [:]) async throws -> Data {
        let frame = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        let raw: Data = await session.handle(frame: frame)
        let response = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        try #require(response["ok"] as? Bool == true, "\(method): \(response)")
        return try JSONSerialization.data(withJSONObject: response["result"] ?? [:])
    }

    @Test func shippedPhoneFlowListsReplaysTypesAndSeesOutput() async throws {
        try await LiveDaemon.with { _, endpoint in
            let backend = try await DaemonCompatBackend.connect(endpointProvider: { endpoint })
            let recorder = EventRecorder()
            let host = MobileCompatHostInfo(macDeviceID: "m", instanceTag: "it", bundleIdentifier: "com.cmuxterm.app.debug.it",
                                            displayName: "it", appVersion: "0", appBuild: "0", daemonLaneAvailable: true)
            let session = MobileCompatSession(backend: backend, host: host, emit: recorder.emit())
            _ = try await call(session, "mobile.events.subscribe", ["client_id": "p", "stream_id": "s"])
            let created = try MobileSyncWorkspaceListResponse.decode(try await call(session, "workspace.create", ["title": "phone"]))
            let workspace = try #require(created.workspaces.first { $0.title == "phone" })
            let surface = try #require(workspace.terminals.first?.id)

            let replay = try JSONDecoder().decode(MobileTerminalReplayResponse.self, from: try await call(
                session, "mobile.terminal.replay",
                ["workspace_id": workspace.id, "surface_id": surface, "client_id": "p",
                 "viewport_columns": 60, "viewport_rows": 20]))
            #expect(replay.surfaceID == surface)
            #expect(replay.snapshotBase64.flatMap { Data(base64Encoded: $0) } != nil)
            // The replay reports the grid at attach time; the phone's geometry
            // claim then arrives as a `resized` replacement in terminal.bytes.
            #expect(replay.columns != nil && replay.rows != nil)

            _ = try await call(session, "terminal.input", ["workspace_id": workspace.id, "surface_id": surface,
                                                           "text": "echo hi-$((40+2))\r"])
            var output = Data()
            var nextSeq = replay.sequence ?? 0
            for count in 1...400 {
                await recorder.wait(for: count)
                let frames = await recorder.frames
                guard let object = try? JSONSerialization.jsonObject(with: frames[count - 1]) as? [String: Any],
                      object["topic"] as? String == "terminal.bytes",
                      let payload = try? JSONSerialization.data(withJSONObject: object["payload"] ?? [:]),
                      let event = MobileTerminalBytesEvent.decode(payload) else { continue }
                #expect(event.sequence == nextSeq, "byte sequence must be contiguous")
                nextSeq += UInt64(event.bytes.count)
                output.append(event.bytes)
                if String(decoding: output, as: UTF8.self).contains("hi-42") { break }
            }
            #expect(String(decoding: output, as: UTF8.self).contains("hi-42"))
            await session.close()
            await backend.close()
        }
    }

    @Test func daemonLaneSplicesToRealSocketAndRefusesShutdown() async throws {
        try await LiveDaemon.with { control, endpoint in
            let (phoneSide, phoneRemote) = MemoryLane.pair()
            let daemon = try await UnixSocketLane.connect(path: endpoint.socketPath)
            let splice = DaemonLaneSplice(phone: phoneSide, daemon: daemon, policy: DaemonLanePolicy(deviceID: "p"))
            let run = Task { await splice.run() }
            try await phoneRemote.write(Data(#"{"id":"a","cmd":"identify"}"#.utf8 + [0x0A]))
            try await phoneRemote.write(Data(#"{"id":"b","cmd":"shutdown-daemon","force":true}"#.utf8 + [0x0A]))
            try await phoneRemote.write(Data(#"{"id":"c","cmd":"list-workspaces"}"#.utf8 + [0x0A]))
            let lines = await phoneRemote.readLines(3)
            let byID = Dictionary(uniqueKeysWithValues: lines.compactMap { line -> (String, [String: Any])? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = object["id"] as? String else { return nil }
                return (id, object)
            })
            #expect(byID["a"]?["ok"] as? Bool == true)
            #expect(byID["b"]?["error_code"] as? String == "forbidden")
            #expect(byID["c"]?["ok"] as? Bool == true)
            // The daemon survived the refused shutdown.
            #expect((try? await control.listWorkspaces()) != nil)
            await phoneRemote.close()
            #expect(await run.value == .phoneClosed)
        }
    }
}
