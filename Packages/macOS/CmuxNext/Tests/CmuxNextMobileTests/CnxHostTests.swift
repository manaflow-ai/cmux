import Foundation
import Testing
@testable import CmuxNextMobile

/// The cnx iPhone host's app side: hostd's status lines, the state they fold
/// into, the child's environment, the device id file, and the supervisor
/// against a stand-in hostd script.
@Suite struct CnxHostTests {
    @Test func parsesEveryHostdEvent() {
        #expect(CnxHostEvent(line: #"{"type":"connecting"}"#) == .connecting)
        #expect(CnxHostEvent(line: #"{"type":"online","device_id":"d","team_id":"t"}"#) == .online(deviceID: "d", teamID: "t"))
        #expect(CnxHostEvent(line: #"{"type":"waiting","reason":"x","retry_in_seconds":4}"#) == .waiting(reason: "x", retryInSeconds: 4))
        #expect(CnxHostEvent(line: #"{"type":"need_token"}"#) == .needToken)
        #expect(CnxHostEvent(line: #"{"type":"need_acpmux"}"#) == .needAcpmux)
        #expect(CnxHostEvent(line: #"{"type":"phone_up","session_id":"s","phone_device_id":"p","transport":"wireguard","path":"relay"}"#)
            == .phoneUp(CnxPhoneLink(sessionID: "s", phoneDeviceID: "p", transport: "wireguard", path: "relay")))
        #expect(CnxHostEvent(line: #"{"type":"phone_path","session_id":"s","path":"direct"}"#) == .phonePath(sessionID: "s", path: "direct"))
        #expect(CnxHostEvent(line: #"{"type":"phone_down","session_id":"s","reason":"eof"}"#) == .phoneDown(sessionID: "s", reason: "eof"))
        #expect(CnxHostEvent(line: #"{"type":"online"}"#) == nil)
        #expect(CnxHostEvent(line: "2026-10-13 INFO not json") == nil)
    }

    @Test func stateTracksPhasesAndPhones() {
        let at = Date(timeIntervalSince1970: 1_000)
        var state = CnxHostState(phase: .connecting)
        state.apply(.online(deviceID: "d", teamID: "t"), at: at)
        #expect(state.phase == .online && state.teamID == "t" && state.deviceID == "d")
        state.apply(.phoneUp(CnxPhoneLink(sessionID: "a", phoneDeviceID: "p", transport: "webrtc", path: "direct")), at: at)
        state.apply(.phoneUp(CnxPhoneLink(sessionID: "b", phoneDeviceID: "q", transport: "wireguard", path: "relay")), at: at)
        state.apply(.phonePath(sessionID: "b", path: "direct"), at: at)
        #expect(state.phones.map(\.sessionID) == ["a", "b"])
        #expect(state.phones[1].path == "direct" && state.phones[0].since == at)
        // A signaling reconnect keeps live links; only their own down event ends them.
        state.apply(.waiting(reason: "signaling closed", retryInSeconds: 1), at: at)
        #expect(state.phase == .waiting("signaling closed") && state.phones.count == 2)
        state.apply(.phoneDown(sessionID: "a", reason: "eof"), at: at)
        #expect(state.phones.map(\.sessionID) == ["b"])
        state.reset(to: .off)
        #expect(state.phase == .off && state.phones.isEmpty)
    }

    @Test func teamIsTheSelectedOneElseThePersonalSpace() {
        #expect(CnxHostLaunch.teamID(selected: "team_1", userID: "u") == "team_1")
        #expect(CnxHostLaunch.teamID(selected: nil, userID: "u") == "personal-u")
        #expect(CnxHostLaunch.teamID(selected: "", userID: "u") == "personal-u")
    }

    @Test func environmentPointsAtTheAppsDaemonAndLeaksNothingElse() {
        let launch = Self.launch(executable: URL(fileURLWithPath: "/bin/cnx-hostd"))
        let environment = launch.environment(inherited: ["HOME": "/Users/me", "PATH": "/usr/bin", "TMPDIR": "/tmp/x",
                                                         "CMUX_SOCKET_PASSWORD": "secret", "CNX_REFRESH_TOKEN": "nope"])
        #expect(environment["CNX_CONTROL"] == "stdio")
        #expect(environment["CNX_TUI_SOCKET"] == "/tmp/cmux-tui-501/cmux-app-tag.sock")
        #expect(environment["CNX_TUI_SOCKET_DIR"] == "/tmp/cmux-tui-501")
        #expect(environment["CNX_TUI_SESSION"] == "cmux-app-tag")
        #expect(environment["CNX_TEAM_ID"] == "personal-u")
        #expect(environment["CNX_OWNER_USER_ID"] == "u")
        #expect(environment["CNX_FILE_ROOTS"] == "/a:/b")
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["CMUX_SOCKET_PASSWORD"] == nil)
        #expect(environment["CNX_REFRESH_TOKEN"] == nil)
        #expect(environment.keys.allSatisfy { !$0.lowercased().contains("token") })
    }

    @Test func controlLinesAreSingleJSONLines() throws {
        let line = CnxHostLaunch.tokenLine("a.b.c")
        #expect(line.last == 0x0A)
        let object = try #require(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: String])
        #expect(object == ["type": "token", "token": "a.b.c"])
        let acpmux = CnxHostLaunch.acpmuxLine(url: try #require(URL(string: "ws://127.0.0.1:4/")), token: "t")
        #expect(String(decoding: acpmux, as: UTF8.self) == #"{"token":"t","type":"acpmux","url":"ws:\/\/127.0.0.1:4\/"}"# + "\n")
    }

    @Test func deviceIDPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cnx-device-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = CnxDeviceIdentity(directory: directory)
        let first = try identity.deviceID()
        #expect(UUID(uuidString: first) != nil)
        #expect(try identity.deviceID() == first)
        let mode = try FileManager.default.attributesOfItem(atPath: identity.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    /// A stand-in hostd: reports online and one phone once it has a token,
    /// asks for acpmux, and exits when stdin closes (as hostd does).
    @Test(.timeLimit(.minutes(1))) func supervisorRunsHostdAndStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cnx-sup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cnx-hostd")
        try """
        #!/bin/sh
        echo '{"type":"connecting"}'
        read token
        case "$token" in *'"type":"token"'*) ;; *) exit 3 ;; esac
        echo '{"type":"online","device_id":"d","team_id":"personal-u"}'
        echo '{"type":"phone_up","session_id":"s","phone_device_id":"phone","transport":"wireguard","path":"relay"}'
        while read line; do :; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let supervisor = CnxHostSupervisor()
        let states = supervisor.states
        await supervisor.start(.init(launch: Self.launch(executable: script), accessToken: { _ in "h.e.s" },
                                     acpmux: { nil }, log: directory.appendingPathComponent("log")))
        var reached = false
        for await state in states where state.phase == .online && state.phones.count == 1 {
            #expect(state.phones.first?.phoneDeviceID == "phone")
            reached = true
            break
        }
        #expect(reached)
        await supervisor.stop()
        #expect(await supervisor.current.phase == .off)
        #expect(await supervisor.current.phones.isEmpty)
    }

    @Test func missingHostdIsUnavailable() async {
        let supervisor = CnxHostSupervisor()
        await supervisor.start(.init(launch: Self.launch(executable: URL(fileURLWithPath: "/nonexistent/cnx-hostd")),
                                     accessToken: { _ in "t" }, acpmux: { nil }, log: nil))
        if case .unavailable = await supervisor.current.phase {} else { Issue.record("expected unavailable") }
    }

    static func launch(executable: URL) -> CnxHostLaunch {
        CnxHostLaunch(executable: executable, baseURL: URL(fileURLWithPath: "/dev/null"), teamID: "personal-u", userID: "u",
                      deviceID: "d", deviceName: "Mac", daemonSocket: "/tmp/cmux-tui-501/cmux-app-tag.sock",
                      stateDirectory: URL(fileURLWithPath: "/tmp/cnx-state"), fileRoots: ["/a", "/b"], stackProjectID: "p")
    }
}
