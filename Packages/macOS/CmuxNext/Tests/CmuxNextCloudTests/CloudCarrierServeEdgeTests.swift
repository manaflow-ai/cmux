@testable import CmuxNextCloud
import Foundation
import Testing

/// ``CloudCarrierServe``, the app's edge of `cmux carrier supervise` (whose serve lifecycle and its tests are
/// Rust's: cmux-tui `carrier/serve_machine_tests.rs`, `carrier/supervise_tests.rs`). A shell stand-in
/// speaks the supervisor's lines: it asks a token for each connect (read id = the connect's id) and answers
/// the token with a socket, a refusal, or `closed` for a fenced read.
@Suite struct CloudCarrierServeEdgeTests {
    static let socket = "/tmp/cmux-link-0123456789ab.sock"
    static let ready = #"printf '{"state":{"refusal":null,"answer":"team"}}\n{"publish":"team"}\n{"resume":[%s],"socket":"%s"}\n' "$n" "$6" >&2"#

    /// The stand-in supervisor; `answer` runs for each token reply with the read id in `$n`.
    private static func standIn(answer: String = ready) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("cmux-tui")
        let body = """
        #!/bin/sh
        d=$(dirname "$0")
        echo "$*" >> "$d/launches"
        while IFS= read -r l; do
          printf '%s\\n' "$l" >> "$d/stdin"
          case "$l" in
            *'"connect"'*) n=$(printf '%s' "$l" | sed 's/.*"connect":\\([0-9]*\\).*/\\1/'); printf '{"read_token":%s}\\n' "$n" >&2 ;;
            *'"fenced"'*) n=$(printf '%s' "$l" | sed 's/.*"token":\\([0-9]*\\).*/\\1/'); printf '{"resume":[%s],"error":{"kind":"disconnected","reason":"closed"}}\\n' "$n" >&2 ;;
            *'"token"'*) n=$(printf '%s' "$l" | sed 's/.*"token":\\([0-9]*\\).*/\\1/'); \(answer) ;;
            *'"stop"'*|*'"account_ended"'*) exit 0 ;;
          esac
        done
        """
        try body.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    private static func connector(_ cli: URL, streams: CloudCarrierStreams? = nil,
                                  environment: @escaping @Sendable () async throws -> [String: String] = { ["CMUX_CLOUD_ACCESS_TOKEN": "t-1"] })
        throws -> CloudCarrierDial.Connector {
        CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux)), streams: streams,
                                   environment: environment)
    }

    private static func text(_ folder: URL, _ name: String) -> String {
        (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    /// Waits (bounded) until `name` in `folder` holds `needle`.
    private static func eventually(_ folder: URL, _ name: String, contains needle: String) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !text(folder, name).contains(needle), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return text(folder, name).contains(needle)
    }

    @Test func aConnectGetsTheSupervisorsSocketWithTheConnectorsToken() async throws {
        let cli = try Self.standIn()
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let serve = CloudCarrierServe(connector: try Self.connector(cli), socket: Self.socket)
        let answers = Answers()
        await serve.observeOwnership { await answers.add($0) }
        #expect(try await serve.socketPath() == Self.socket)
        #expect(await serve.answer == .team, "the state line before the resume")
        #expect(await serve.refusal == nil)
        #expect(Self.text(folder, "launches") == "carrier supervise --machine vm_abc123 --socket \(Self.socket)\n")
        #expect(Self.text(folder, "stdin").contains(#""CMUX_CLOUD_ACCESS_TOKEN":"t-1""#), "the token read's answer")
        #expect(try await serve.socketPath(keepingRefusal: true) == Self.socket)
        #expect(Self.text(folder, "launches").split(separator: "\n").count == 1, "one supervisor for every connect")
        #expect(Self.text(folder, "stdin").contains(#""keep_refusal":true"#))
        #expect(await answers.first() == .team)
        await serve.stop()
    }

    @Test func theSupervisorsRefusalIsTheLinksRefusal() async throws {
        let refused = #"printf '{"state":{"refusal":{"kind":"not_up","state":"parked_timeout"},"answer":null}}\n{"resume":[%s],"error":{"kind":"not_up","state":"parked_timeout"}}\n' "$n" >&2"#
        let cli = try Self.standIn(answer: refused)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let serve = CloudCarrierServe(connector: try Self.connector(cli), socket: Self.socket)
        await #expect(throws: CloudLinkError.notUp(state: "parked_timeout")) { try await serve.socketPath() }
        #expect(await serve.refusal == .notUp(state: "parked_timeout"))
        await serve.stop()
    }

    /// A stop ends the supervisor (its child with it) for good: later connects fail closed and start nothing.
    @Test func aStopIsTerminal() async throws {
        let cli = try Self.standIn()
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let serve = CloudCarrierServe(connector: try Self.connector(cli), socket: Self.socket)
        _ = try await serve.socketPath()
        await serve.stop()
        #expect(try await Self.eventually(folder, "stdin", contains: #""stop":true"#))
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { try await serve.socketPath() }
        #expect(await serve.refusal == .disconnected(reason: "closed"))
        #expect(Self.text(folder, "launches").split(separator: "\n").count == 1, "no new supervisor")
    }

    /// A park goes to the running supervisor, which keeps serving the next connect.
    @Test func aParkGoesToTheSupervisor() async throws {
        let cli = try Self.standIn()
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let serve = CloudCarrierServe(connector: try Self.connector(cli), socket: Self.socket)
        _ = try await serve.socketPath()
        await serve.park()
        #expect(try await serve.socketPath() == Self.socket, "a resume connects again")
        let lines = Self.text(folder, "stdin").split(separator: "\n").map(String.init)
        #expect(lines.firstIndex { $0.contains(#""park":true"#) }.map { $0 < lines.count - 2 } == true, "the park came before the next connect")
        await serve.stop()
    }

    /// An account end (``CloudCarrierStreams/endAll()``) tells the supervisor at once and fences the serve.
    @Test func anAccountEndStopsTheSupervisorAndFencesItsSocket() async throws {
        let cli = try Self.standIn()
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let streams = CloudCarrierStreams()
        let serve = CloudCarrierServe(connector: try Self.connector(cli, streams: streams), socket: Self.socket)
        _ = try await serve.socketPath()
        #expect(streams.count == 1, "the running supervisor is held")
        await streams.endAll().value
        #expect(try await Self.eventually(folder, "stdin", contains: #""account_ended":true"#))
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { try await serve.socketPath(keepingRefusal: true) }
        #expect(Self.text(folder, "launches").split(separator: "\n").count == 1, "no new supervisor")
    }

    /// A token read the connector fences (the account switched during it) is answered `fenced`.
    @Test func aFencedTokenReadIsAnsweredFenced() async throws {
        let cli = try Self.standIn()
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let serve = CloudCarrierServe(connector: try Self.connector(cli) { throw CloudCarrierDial.Connector.fenced }, socket: Self.socket)
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { try await serve.socketPath() }
        #expect(Self.text(folder, "stdin").contains(#""fenced":true"#))
        #expect(!Self.text(folder, "stdin").contains("CMUX_CLOUD_ACCESS_TOKEN"))
        await serve.stop()
    }

    /// A supervisor that exits fails the connects it held with its status and last stderr line; the next
    /// connect starts another.
    @Test func aSupervisorThatExitsFailsItsConnectsAndTheNextStartsAnother() async throws {
        let cli = try Self.standIn(answer: "echo 'cmux: no such verb' >&2; exit 3")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let serve = CloudCarrierServe(connector: try Self.connector(cli), socket: Self.socket)
        let exited = CloudLinkError.helperNotRunning(reason: "cmux carrier supervise exited with status 3; its last stderr line: cmux: no such verb")
        await #expect(throws: exited) { try await serve.socketPath() }
        await #expect(throws: exited) { try await serve.socketPath() }
        #expect(Self.text(folder, "launches").split(separator: "\n").count == 2)
        await serve.stop()
    }

    /// A paused machine's carrier ask from the Cloud app server is refused as paused and starts no supervisor.
    @Test func aPausedMachinesCarrierAskStartsNoServe() async throws {
        let cli = try Self.standIn()
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let serve = CloudCarrierServe(connector: try Self.connector(cli), socket: Self.socket)
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        let answer = await CloudLinkSession.carrierAnswer(link, machine: "vm_abc123", paused: true)
        #expect(answer == .failure(.init(code: "cloud.machine.paused", message: "vm_abc123 is paused; resume it first")))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("launches").path), "no supervisor started")
        await link.close()
    }

    /// A line longer than the pipe takes at once (a token answer is ~1.5 KB, past `PIPE_BUF`) goes in whole
    /// as the child reads; before, the one non-blocking write took a part, the rest was dropped and the
    /// supervisor never saw its answer.
    @Test func aLongLineGoesInWholeWhileTheChildReads() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("stdin")
        let child = ChildProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"sleep 0.3; cat > "$0""#, out.path])
        try child.startHoldingInput()
        let line = String(repeating: "x", count: 256 * 1024)
        #expect(child.writeInput(line: line, patience: .seconds(10)), "the whole line went in")
        child.closeInput()
        _ = await child.waitForExit()
        #expect((try? Data(contentsOf: out).count) == line.utf8.count + 1)
    }

    @Test func everyLinkErrorRoundTripsOnTheSupervisorsWire() {
        let errors: [CloudLinkError] = [
            .disconnected(reason: "closed"), .revoked(reason: "r"), .helperNotRunning(reason: "gone"), .unsafeSocket("x"),
            .openDirectory(path: "/tmp/x", parent: true), .invalidAnswer("y"), .notUp(state: "parked_timeout"),
            .failed(code: "ticket", message: "ticket: no"), .unsupported,
        ]
        for error in errors { #expect(CloudLinkError(wire: error.wire) == error, "\(error)") }
        #expect(CloudLinkError(wire: ["kind": "nonsense"]) == nil)
    }

    private actor Answers {
        private var seen: [CloudCallerOwnership] = []
        func add(_ caller: CloudCallerOwnership) { seen.append(caller) }
        func first() async -> CloudCallerOwnership? {
            let deadline = ContinuousClock.now + .seconds(5)
            while seen.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return seen.first
        }
    }
}
