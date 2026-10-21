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
        #expect(environment["CNX_AGENT_TAB_HOST"] == nil)
        var withHost = launch
        withHost.agentTabHost = "install:mac-1"
        #expect(withHost.environment(inherited: [:])["CNX_AGENT_TAB_HOST"] == "install:mac-1")
        #expect(environment["CNX_CHIEF_SESSION"] == nil)
        // Browser tabs only from a build that bundles the host (Release has none yet).
        #expect(environment["CNX_BROWSER_HOSTS"] == nil)
        var withBrowser = launch
        withBrowser.browserHosts = true
        #expect(withBrowser.environment(inherited: [:])["CNX_BROWSER_HOSTS"] == "1")
        var chief = launch
        chief.chiefSession = "cmux-chief-c39c6f72"
        #expect(chief.environment(inherited: [:])["CNX_CHIEF_SESSION"] == "cmux-chief-c39c6f72")
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

    @Test func parsesBrowserRequestsAndWritesTheAnswers() throws {
        #expect(CnxHostEvent(line: #"{"type":"need_browser","request":7,"tab":"s4","url":"https://example.com"}"#)
            == .needBrowser(request: 7, tab: "s4", url: "https://example.com"))
        #expect(CnxHostEvent(line: #"{"type":"browser_stop","tab":"s4"}"#) == .browserStop(tab: "s4"))
        #expect(CnxHostEvent(line: #"{"type":"need_browser","tab":"s4"}"#) == nil)
        let answer = try #require(String(data: CnxHostLaunch.browserLine(request: 7, port: 4567, secret: "ab"), encoding: .utf8))
        #expect(answer == #"{"addr":"127.0.0.1:4567","request":7,"secret":"ab","type":"browser"}"# + "\n")
        let gone = try #require(String(data: CnxHostLaunch.browserGoneLine(tab: "s4"), encoding: .utf8))
        #expect(gone == #"{"tab":"s4","type":"browser_gone"}"# + "\n")
    }

    /// Records what the supervisor asks of the app's browser hosts.
    final class FakeBrowserHosts: CnxBrowserHosting, @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []

        func record(_ call: String) { lock.withLock { calls.append(call) } }
        func snapshot() -> [String] { lock.withLock { calls } }

        func start(tab: String, url: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
            record("start \(tab) \(url)")
            return (4567, "s3cr3t")
        }
        func stop(tab: String) async { record("stop \(tab)") }
        func stopAll() async { record("stopAll") }
    }

    @Test(.timeLimit(.minutes(1))) func supervisorStartsBrowserHostsForHostd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cnx-br-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cnx-hostd")
        let answer = directory.appendingPathComponent("answer")
        try """
        #!/bin/sh
        read token
        echo '{"type":"need_browser","request":7,"tab":"s4","url":"https://example.com/"}'
        while read line; do
          case "$line" in *'"type":"browser"'*) echo "$line" > '\(answer.path)'; break ;; esac
        done
        echo '{"type":"browser_stop","tab":"s4"}'
        echo '{"type":"online","device_id":"d","team_id":"personal-u"}'
        while read line; do :; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let hosts = FakeBrowserHosts()
        let supervisor = CnxHostSupervisor()
        let states = supervisor.states
        await supervisor.start(.init(launch: Self.launch(executable: script), accessToken: { _ in "h.e.s" },
                                     acpmux: { nil }, log: nil, browserHosts: hosts))
        for await state in states where state.phase == .online { break }
        let line = try String(contentsOf: answer, encoding: .utf8)
        #expect(line.contains(#""addr":"127.0.0.1:4567""#) && line.contains(#""request":7"#) && line.contains("s3cr3t"))
        #expect(hosts.snapshot().first == "start s4 https://example.com/")
        await supervisor.stop()
        #expect(hosts.snapshot().contains("stopAll"))
    }

    @Test func missingHostdIsUnavailable() async {
        let supervisor = CnxHostSupervisor()
        await supervisor.start(.init(launch: Self.launch(executable: URL(fileURLWithPath: "/nonexistent/cnx-hostd")),
                                     accessToken: { _ in "t" }, acpmux: { nil }, log: nil))
        if case .unavailable = await supervisor.current.phase {} else { Issue.record("expected unavailable") }
    }

    @Test func phonesGroupTheirLinkAndPresenceIDs() {
        let phones = CnxKnownPhone.group([
            CnxRegisteredDevice(deviceID: "a", kind: "phone", name: "Aziz's iPhone", updatedAt: "2026-10-13T10:00:00Z"),
            CnxRegisteredDevice(deviceID: "m", kind: "mac", name: "Studio"),
            CnxRegisteredDevice(deviceID: "b", kind: "phone", name: "Aziz's iPhone (presence)", updatedAt: "2026-10-13T11:00:00Z"),
            CnxRegisteredDevice(deviceID: "c", kind: "phone", name: "Old iPhone"),
        ])
        #expect(phones.map(\.name) == ["Aziz's iPhone", "Old iPhone"])
        #expect(phones[0].deviceIDs == ["a", "b"])
        #expect(phones[0].updatedAt == "2026-10-13T11:00:00Z")
        #expect(phones[0].owns("A") && !phones[0].owns("c"))
        // Two phones with one name never join: Remove must not take both.
        let twins = CnxKnownPhone.group([
            CnxRegisteredDevice(deviceID: "x", kind: "phone", name: "iPhone"),
            CnxRegisteredDevice(deviceID: "y", kind: "phone", name: "iPhone"),
            CnxRegisteredDevice(deviceID: "z", kind: "phone", name: "iPhone (presence)"),
        ])
        #expect(twins.map(\.deviceIDs) == [["x"], ["y"], ["z"]])
    }

    @Test func aRemovalIsAPhaseThatDropsPhones() {
        #expect(CnxHostEvent(line: #"{"type":"removed"}"#) == .removed)
        var state = CnxHostState(phase: .online)
        state.apply(.phoneUp(CnxPhoneLink(sessionID: "a", phoneDeviceID: "p", transport: "webrtc", path: "direct")), at: Date())
        state.apply(.removed, at: Date())
        #expect(state.phase == .removed && state.phones.isEmpty)
    }

    @Test func theRemovalMarkerForgetsTheDeviceAndHoldsPerAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cnx-removed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = CnxDeviceIdentity(directory: directory)
        let first = try identity.deviceID()
        let marker = CnxRemovalMarker(directory: directory)
        #expect(marker.account() == nil)
        try marker.record(account: "u\u{0}personal-u", identity: identity)
        #expect(marker.account() == "u\u{0}personal-u")
        // Allowing again registers a new device.
        #expect(try identity.deviceID() != first)
        marker.clear()
        #expect(marker.account() == nil)
    }

    /// hostd reports a removal and exits 78: the supervisor shows it and never restarts.
    @Test(.timeLimit(.minutes(1))) func aRemovedHostdIsNotRestarted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cnx-rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cnx-hostd")
        let starts = directory.appendingPathComponent("starts")
        try """
        #!/bin/sh
        echo start >> "\(starts.path)"
        echo '{"type":"removed"}'
        exit 78
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let supervisor = CnxHostSupervisor()
        let states = supervisor.states
        await supervisor.start(.init(launch: Self.launch(executable: script), accessToken: { _ in "t" }, acpmux: { nil }, log: nil))
        for await state in states where state.phase == .removed { break }
        // A restart would come after the first backoff (1 s ± 20%); wait past it.
        try await Task.sleep(for: .seconds(2))
        #expect(await supervisor.current.phase == .removed)
        let runs = try String(contentsOf: starts, encoding: .utf8).split(separator: "\n").count
        #expect(runs == 1)
        await supervisor.stop()
    }

    /// termqa (cnx-ios round 4): hostd killed every 13-45 s came back after 7, 16,
    /// 32 and 61 s, because only a minute-long run reset the restart backoff. A run
    /// that reached the service and stayed up a few seconds is not a crash loop:
    /// the next restart is at the first delay, so phones reconnect within seconds.
    @Test func aRunThatCameOnlineRestartsAtTheFirstDelay() {
        let start = Date(timeIntervalSince1970: 1_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        // Online after 1 s, killed 12 s later: healthy.
        #expect(CnxHostSupervisor.resetsBackoff(started: start, online: at(1), ended: at(13)))
        // Never online: a crash loop keeps backing off.
        #expect(!CnxHostSupervisor.resetsBackoff(started: start, online: nil, ended: at(13)))
        // Online, then gone within the settle time: still a crash loop.
        #expect(!CnxHostSupervisor.resetsBackoff(started: start, online: at(1), ended: at(3)))
        // A minute up resets whatever it did.
        #expect(CnxHostSupervisor.resetsBackoff(started: start, online: nil, ended: at(60)))
    }

    @Test func dropPhoneIsOneControlLine() {
        #expect(String(decoding: CnxHostLaunch.dropPhoneLine("p1"), as: UTF8.self) == #"{"phone_device_id":"p1","type":"drop_phone"}"# + "\n")
    }

    @Test func directoryListsAndRemovesWithTheBearerToken() async throws {
        let base = try #require(URL(string: "https://cnx.test"))
        let log = RequestLog()
        let directory = CnxDeviceDirectory(baseURL: base) { request in
            await log.add(request)
            if request.httpMethod == "DELETE" {
                return (Data(), request.url?.lastPathComponent == "b" ? 404 : 200)
            }
            let body = #"{"devices":[{"deviceId":"a","kind":"phone","name":"P"},{"deviceId":"b","kind":"phone","name":"P (presence)"}]}"#
            return (Data(body.utf8), 200)
        }
        let phones = try await directory.phones(token: "tok")
        #expect(phones.count == 1)
        try await directory.remove(try #require(phones.first), token: "tok")
        let requests = await log.requests
        #expect(requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" } == ["GET /v1/me/devices", "DELETE /v1/devices/a", "DELETE /v1/devices/b"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
        let failing = CnxDeviceDirectory(baseURL: base) { _ in (Data(), 502) }
        await #expect(throws: CnxDeviceDirectory.Failure.status(502)) { try await failing.phones(token: "tok") }
    }

    static func launch(executable: URL) -> CnxHostLaunch {
        CnxHostLaunch(executable: executable, baseURL: URL(fileURLWithPath: "/dev/null"), teamID: "personal-u", userID: "u",
                      deviceID: "d", deviceName: "Mac", daemonSocket: "/tmp/cmux-tui-501/cmux-app-tag.sock",
                      stateDirectory: URL(fileURLWithPath: "/tmp/cnx-state"), fileRoots: ["/a", "/b"], stackProjectID: "p")
    }
}

/// Requests a test directory saw, in order.
actor RequestLog {
    private(set) var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
}

