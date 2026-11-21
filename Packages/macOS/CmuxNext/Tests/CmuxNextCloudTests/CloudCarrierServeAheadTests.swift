@testable import CmuxNextCloud
import Foundation
import Testing

/// ``CloudCarrierServe/dialAhead(limit:keep:)``: the one connection that makes the serve dial its machine before the
/// session's first connect, held until that connect or the end of its keep. A shell stand-in speaks the supervisor's
/// lines (as in ``CloudCarrierServeEdgeTests``) and says whatever line the test writes to its `say` pipe; the test
/// itself listens on the serving socket, in place of the serve child. Nothing here blocks a thread: each wait asks
/// without waiting and yields between asks.
@Suite struct CloudCarrierServeAheadTests {
    /// The stand-in supervisor: a connect is answered with the socket and no connected line; each line written to
    /// `say` beside it goes out as one of its own.
    private static func standIn() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cca-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("cmux-tui")
        let body = """
        #!/bin/sh
        d=$(dirname "$0")
        mkfifo "$d/say"
        ( while :; do while IFS= read -r w; do printf '%s\\n' "$w" >&2; done < "$d/say"; done ) &
        say=$!
        trap 'kill $say 2>/dev/null' EXIT
        while IFS= read -r l; do
          printf '%s\\n' "$l" >> "$d/stdin"
          case "$l" in
            *'"connect"'*) n=$(printf '%s' "$l" | sed 's/.*"connect":\\([0-9]*\\).*/\\1/'); printf '{"read_token":%s}\\n' "$n" >&2 ;;
            *'"token"'*) n=$(printf '%s' "$l" | sed 's/.*"token":\\([0-9]*\\).*/\\1/'); printf '{"resume":[%s],"socket":"%s"}\\n' "$n" "$6" >&2 ;;
            *'"stop"'*|*'"account_ended"'*) exit 0 ;;
          esac
        done
        """
        try body.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    private static func serve(_ cli: URL, socket: String) throws -> CloudCarrierServe {
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))
        return CloudCarrierServe(connector: .init(cli: cli, dial: dial) { ["CMUX_CLOUD_ACCESS_TOKEN": "t-1"] }, socket: socket)
    }

    /// One supervisor line, through the stand-in's `say` pipe (opened without waiting for its reader, asked again
    /// until the stand-in reads).
    private static func say(_ cli: URL, _ line: String) async throws {
        let path = cli.deletingLastPathComponent().appendingPathComponent("say").path
        let deadline = ContinuousClock.now + .seconds(5)
        var pipe = open(path, O_WRONLY | O_NONBLOCK)
        while pipe < 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            pipe = open(path, O_WRONLY | O_NONBLOCK)
        }
        try #require(pipe >= 0, "the stand-in reads its say pipe")
        defer { close(pipe) }
        let bytes = Array((line + "\n").utf8)
        #expect(write(pipe, bytes, bytes.count) == bytes.count)
    }

    /// The dial is one connection on the serving socket; the serve's connected line is its answer; the connection
    /// stays open (the serve keeps the session it dialed) until the session's own connect.
    @Test func aDialAheadConnectsAndIsHeldUntilTheSessionConnects() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let listener = try Listener()
        let serve = try Self.serve(cli, socket: listener.path)
        _ = try await serve.socketPath()
        async let dialed = serve.dialAhead(limit: .seconds(5), keep: .seconds(60))
        let connection = try #require(await listener.accepted())
        defer { close(connection) }
        try await Self.say(cli, #"{"publish":"owner"}"#)
        #expect(await dialed)
        #expect(await serve.answer == .owner)
        #expect(!Listener.isClosed(connection), "held open after the dial")
        #expect(try await serve.socketPath() == listener.path)
        #expect(await Listener.closed(connection), "dropped at the session's connect")
        await serve.stop()
    }

    /// A session that connects while the serve still dials takes over: the connection is dropped (the serve goes on
    /// dialing for it, and the session's connection joins that dial), and the dial's answer is still told.
    @Test func aSessionThatConnectsWhileTheDialRunsDropsTheConnection() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let listener = try Listener()
        let serve = try Self.serve(cli, socket: listener.path)
        _ = try await serve.socketPath()
        async let dialed = serve.dialAhead(limit: .seconds(5), keep: .seconds(60))
        let connection = try #require(await listener.accepted())
        defer { close(connection) }
        _ = try await serve.socketPath()
        #expect(await Listener.closed(connection), "dropped at the session's connect")
        try await Self.say(cli, #"{"state":{"refusal":null,"answer":"owner"}}"#)
        #expect(await dialed)
        await serve.stop()
    }

    /// A refused dial answers false and holds nothing: the serve closed its end.
    @Test func aRefusedDialAheadAnswersFalseAndHoldsNothing() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let listener = try Listener()
        let serve = try Self.serve(cli, socket: listener.path)
        _ = try await serve.socketPath()
        async let dialed = serve.dialAhead(limit: .seconds(5), keep: .seconds(60))
        let connection = try #require(await listener.accepted())
        defer { close(connection) }
        try await Self.say(cli, #"{"state":{"refusal":{"kind":"not_up","state":"parked_timeout"},"answer":null}}"#)
        #expect(await dialed == false)
        #expect(await serve.refusal == .notUp(state: "parked_timeout"))
        #expect(await Listener.closed(connection), "nothing is held after a refusal")
        await serve.stop()
    }

    /// The connection is held only for its keep: past it the serve is left to close the idle session itself.
    @Test func theConnectionIsDroppedAtTheEndOfItsKeep() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let listener = try Listener()
        let serve = try Self.serve(cli, socket: listener.path)
        _ = try await serve.socketPath()
        async let dialed = serve.dialAhead(limit: .seconds(5), keep: .milliseconds(50))
        let connection = try #require(await listener.accepted())
        defer { close(connection) }
        try await Self.say(cli, #"{"publish":"owner"}"#)
        #expect(await dialed)
        #expect(await Listener.closed(connection), "dropped at the end of its keep")
        // The serve is still the session's to take: a connect answers its socket.
        #expect(try await serve.socketPath() == listener.path)
        await serve.stop()
    }

    /// No answer within the limit: false, and the connection stays (the dial goes on in the serve) until a stop.
    @Test func aDialAheadWithNoAnswerInTimeAnswersFalseAndAStopDropsItsConnection() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let listener = try Listener()
        let serve = try Self.serve(cli, socket: listener.path)
        _ = try await serve.socketPath()
        #expect(await serve.dialAhead(limit: .milliseconds(50), keep: .seconds(60)) == false)
        let connection = try #require(await listener.accepted())
        defer { close(connection) }
        #expect(!Listener.isClosed(connection))
        await serve.stop()
        #expect(await Listener.closed(connection), "dropped at the stop")
    }

    /// A serve that is not up (no connect asked for its socket yet), or stopped, dials nothing and starts nothing.
    @Test func aServeThatIsNotUpOrIsStoppedDialsNothing() async throws {
        let cli = try Self.standIn()
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let listener = try Listener()
        let serve = try Self.serve(cli, socket: listener.path)
        #expect(await serve.dialAhead(limit: .seconds(1), keep: .seconds(60)) == false)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stdin").path), "no supervisor started")
        _ = try await serve.socketPath()
        await serve.stop()
        #expect(await serve.dialAhead(limit: .seconds(1), keep: .seconds(60)) == false)
        #expect(listener.acceptedNow() == nil, "no connection was made")
    }

    /// A Unix socket this test listens on, where the serve child's would be.
    private final class Listener: Sendable {
        let path: String
        private let descriptor: Int32

        init() throws {
            let path = "/tmp/cca-\(UUID().uuidString.prefix(8)).sock"
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard descriptor >= 0, bound == 0, listen(descriptor, 4) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
            (self.path, self.descriptor) = (path, descriptor)
        }

        deinit {
            close(descriptor)
            unlink(path)
        }

        /// A connection that already waits to be accepted, nil when none does. Never waits.
        func acceptedNow() -> Int32? {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 0) == 1 else { return nil }
            let connection = accept(descriptor, nil, nil)
            return connection >= 0 ? connection : nil
        }

        /// The next connection, nil when none comes within five seconds.
        func accepted() async -> Int32? {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let connection = acceptedNow() { return connection }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return acceptedNow()
        }

        /// Whether the peer of `connection` closed it. Never waits.
        static func isClosed(_ connection: Int32) -> Bool {
            var waiting = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 0) == 1 else { return false }
            var byte: UInt8 = 0
            return read(connection, &byte, 1) == 0
        }

        /// Whether the peer of `connection` closes it within five seconds.
        static func closed(_ connection: Int32) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !isClosed(connection), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return isClosed(connection)
        }
    }
}
