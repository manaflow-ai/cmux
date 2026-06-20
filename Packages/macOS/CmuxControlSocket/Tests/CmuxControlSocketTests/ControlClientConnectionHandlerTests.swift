import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation
import Testing

/// Records what a ``ControlClientConnectionHandler`` routed to the
/// command-dispatch seam, and replays scripted outcomes.
///
/// When seeded with an authenticator it mirrors the legacy `processSocketLine`:
/// it applies the password gate first (the gate the handler does NOT apply for
/// regular commands — only for the `events.stream` branch), then runs the
/// scripted command outcome. That models the real composition root, where the
/// dispatcher and the handler share one ``ControlPasswordAuthenticator``.
private final class RecordingDispatcher: ControlClientCommandDispatching, @unchecked Sendable {
    // @unchecked: the handler runs on one detached thread and the test only
    // reads these after joining via the socket EOF, so there is no concurrent
    // access in practice. A lock keeps the recorded arrays consistent.
    private let lock = NSLock()
    private var processedLines: [(line: String, authenticated: Bool)] = []
    private var publishedEvents: [(command: String, response: String)] = []
    private var eventsStreamLines: [String] = []
    private let eventsStreamMethod: String
    private let authenticator: ControlPasswordAuthenticator?
    private let onClassifyEventsStream: (@Sendable () -> Void)?
    private let outcome: @Sendable (_ line: String, _ authenticated: Bool) -> ControlClientCommandOutcome

    init(
        eventsStreamMethod: String = "events.stream",
        authenticator: ControlPasswordAuthenticator? = nil,
        onClassifyEventsStream: (@Sendable () -> Void)? = nil,
        outcome: @escaping @Sendable (String, Bool) -> ControlClientCommandOutcome
    ) {
        self.eventsStreamMethod = eventsStreamMethod
        self.authenticator = authenticator
        self.onClassifyEventsStream = onClassifyEventsStream
        self.outcome = outcome
    }

    func isEventsStreamRequest(_ line: String) -> Bool {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return false
        }
        let isStream = method == eventsStreamMethod
        // The handler calls this immediately before building the per-line
        // authenticator, so a hook here lands in the live-toggle window the
        // events.stream gate must observe.
        if isStream { onClassifyEventsStream?() }
        return isStream
    }

    func handleEventsStream(line: String, socket: Int32) {
        lock.withLock { eventsStreamLines.append(line) }
        let payload = Array("EVENTS-STREAM-ACK".utf8)
        _ = payload.withUnsafeBufferPointer { buffer in
            Darwin.write(socket, buffer.baseAddress, buffer.count)
        }
    }

    func processCommandLine(_ line: String, authenticated: Bool) -> ControlClientCommandOutcome {
        // Legacy processSocketLine: auth gate first, then the command body.
        if let authenticator {
            let decision = authenticator.response(for: line, authenticated: authenticated)
            if let response = decision.response {
                return ControlClientCommandOutcome(response: response, authenticated: decision.authenticated)
            }
            lock.withLock { processedLines.append((line, decision.authenticated)) }
            return outcome(line, decision.authenticated)
        }
        lock.withLock { processedLines.append((line, authenticated)) }
        return outcome(line, authenticated)
    }

    func publishCommandEvents(command: String, response: String) {
        lock.withLock { publishedEvents.append((command, response)) }
    }

    func snapshotProcessed() -> [(line: String, authenticated: Bool)] {
        lock.withLock { processedLines }
    }

    func snapshotPublished() -> [(command: String, response: String)] {
        lock.withLock { publishedEvents }
    }

    func snapshotEventsStream() -> [String] {
        lock.withLock { eventsStreamLines }
    }
}

/// A connected `socketpair(2)` driving one handler.
private final class HandlerSocketPair {
    let serverEnd: Int32
    private var clientEnd: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        serverEnd = fds[0]
        clientEnd = fds[1]
    }

    func clientWrite(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(clientEnd, buffer.baseAddress, buffer.count)
        }
    }

    func clientShutdownWrite() {
        // Half-close so the handler's read loop sees EOF and returns.
        shutdown(clientEnd, SHUT_WR)
    }

    func clientReadAll() -> String {
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(clientEnd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            collected.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: collected, as: UTF8.self)
    }

    deinit {
        close(serverEnd)
        if clientEnd >= 0 { close(clientEnd) }
    }
}

/// Serialized: each test drives a real `socketpair(2)` on a detached thread,
/// and parallel runs recycle descriptor numbers across fixtures (the package's
/// documented in-process-fd hazard).
@Suite("ControlClientConnectionHandler", .serialized)
struct ControlClientConnectionHandlerTests {
    private func makeStore(password: String?) -> SocketControlPasswordStore {
        let url = URL(fileURLWithPath: "/tmp/cmux-ctlsock-pw-\(UUID().uuidString).json")
        let store = SocketControlPasswordStore(environment: [:], fileURL: url)
        if let password {
            try? store.savePassword(password)
        }
        return store
    }

    /// Runs `handler.run()` on a detached thread; once it finishes (closing the
    /// server end at EOF) the client drains everything it wrote.
    private func driveHandler(
        pair: HandlerSocketPair,
        store: SocketControlPasswordStore,
        accessMode: SocketControlMode,
        dispatcher: any ControlClientCommandDispatching,
        clientScript: () -> Void
    ) -> String {
        let handler = ControlClientConnectionHandler(
            socket: pair.serverEnd,
            // Same-process peer is a descendant of itself, so the cmuxOnly
            // ancestry gate passes; these tests exercise the auth + dispatch
            // pipeline, not the access-control gate.
            peerProcessID: getpid(),
            transport: SocketTransport(),
            accessMode: { accessMode },
            selfProcessID: getpid(),
            isRunning: { true },
            makeAuthenticator: {
                ControlPasswordAuthenticator(
                    passwordStore: store,
                    accessMode: accessMode
                )
            },
            dispatcher: dispatcher
        )
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handler.run()
            done.signal()
        }
        clientScript()
        pair.clientShutdownWrite()
        done.wait()
        return pair.clientReadAll()
    }

    @Test func noAuthModePassesEveryLineToDispatcher() throws {
        let pair = try HandlerSocketPair()
        let dispatcher = RecordingDispatcher { line, _ in
            ControlClientCommandOutcome(response: "RESP:\(line)", authenticated: false)
        }
        let output = driveHandler(
            pair: pair,
            store: makeStore(password: nil),
            accessMode: .cmuxOnly,
            dispatcher: dispatcher
        ) {
            pair.clientWrite("hello\nworld\n")
        }

        #expect(dispatcher.snapshotProcessed().map(\.line) == ["hello", "world"])
        #expect(output == "RESP:hello\nRESP:world\n")
        #expect(dispatcher.snapshotPublished().map(\.command) == ["hello", "world"])
    }

    @Test func passwordModeV1AuthThenCommandThroughDispatcherGate() throws {
        let pair = try HandlerSocketPair()
        let store = makeStore(password: "hunter2")
        let dispatcher = RecordingDispatcher(
            authenticator: ControlPasswordAuthenticator(passwordStore: store, accessMode: .password)
        ) { line, authenticated in
            ControlClientCommandOutcome(response: "OK:\(line):auth=\(authenticated)", authenticated: authenticated)
        }
        let output = driveHandler(
            pair: pair,
            store: store,
            accessMode: .password,
            dispatcher: dispatcher
        ) {
            pair.clientWrite("auth hunter2\n")
            pair.clientWrite("list-workspaces\n")
        }

        // `auth hunter2` is consumed by the dispatcher's auth gate (legacy
        // processSocketLine) and never reaches the command body; the next
        // command dispatches with authenticated == true.
        #expect(dispatcher.snapshotProcessed().map(\.line) == ["list-workspaces"])
        #expect(dispatcher.snapshotProcessed().first?.authenticated == true)
        #expect(output == "OK: Authenticated\nOK:list-workspaces:auth=true\n")
    }

    @Test func eventsStreamRequestRoutesToStreamHandlerAndClosesAfter() throws {
        let pair = try HandlerSocketPair()
        let dispatcher = RecordingDispatcher { _, _ in
            ControlClientCommandOutcome(response: "UNREACHED", authenticated: false)
        }
        let output = driveHandler(
            pair: pair,
            store: makeStore(password: nil),
            accessMode: .cmuxOnly,
            dispatcher: dispatcher
        ) {
            pair.clientWrite("{\"method\":\"events.stream\"}\n")
            // A trailing line that must never be processed: the handler closes
            // the connection after servicing the events stream.
            pair.clientWrite("after-stream\n")
        }
        #expect(dispatcher.snapshotEventsStream() == ["{\"method\":\"events.stream\"}"])
        #expect(output == "EVENTS-STREAM-ACK")
        #expect(dispatcher.snapshotProcessed().isEmpty)
    }

    @Test func eventsStreamInPasswordModeIsGatedByHandlerBeforeStreaming() throws {
        // The handler applies the password gate to the events.stream branch
        // itself (legacy handleClient inline gate), so an unauthenticated
        // events.stream request gets auth_required and never opens the stream.
        let pair = try HandlerSocketPair()
        let dispatcher = RecordingDispatcher { _, _ in
            ControlClientCommandOutcome(response: nil, authenticated: false)
        }
        let output = driveHandler(
            pair: pair,
            store: makeStore(password: "hunter2"),
            accessMode: .password,
            dispatcher: dispatcher
        ) {
            pair.clientWrite("{\"id\":9,\"method\":\"events.stream\"}\n")
        }
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        #expect(object["id"] as? Int == 9)
        #expect((object["error"] as? [String: Any])?["code"] as? String == "auth_required")
        #expect(dispatcher.snapshotEventsStream().isEmpty)
    }

    @Test func eventsStreamGateReadsAccessModeLiveAfterMidConnectionToggle() throws {
        // Regression: the listener access mode can change on a LIVE listener
        // mid-connection (a Settings socket-mode toggle keeps the same path, so
        // `start` flips `accessMode` in place without `stop()`, and `stop()`
        // never tears down accepted connections). Legacy `handleClient` read
        // `socketServer.accessMode` LIVE for the `events.stream` password gate
        // (via `authResponseIfNeeded`). A connection that opened in `cmuxOnly`
        // (no password) must therefore start requiring auth on its next
        // `events.stream` line once the running listener is switched to
        // `password` — the handler reads the mode live, never a value frozen at
        // connection spawn.
        let pair = try HandlerSocketPair()
        let store = makeStore(password: "hunter2")
        // A thread-safe mode holder read live by the handler's closures. It
        // starts in `cmuxOnly` so the connection-start ancestry gate passes
        // (same-process peer is its own descendant), then flips to `password`
        // on the handler thread itself, the moment it classifies the
        // events.stream line — exactly the live-toggle window legacy covered.
        let modeLock = NSLock()
        nonisolated(unsafe) var liveMode: SocketControlMode = .cmuxOnly
        @Sendable func currentMode() -> SocketControlMode { modeLock.withLock { liveMode } }
        let dispatcher = RecordingDispatcher(
            onClassifyEventsStream: {
                modeLock.withLock { liveMode = .password }
            }
        ) { _, _ in
            ControlClientCommandOutcome(response: nil, authenticated: false)
        }
        let handler = ControlClientConnectionHandler(
            socket: pair.serverEnd,
            peerProcessID: getpid(),
            transport: SocketTransport(),
            accessMode: { currentMode() },
            selfProcessID: getpid(),
            isRunning: { true },
            makeAuthenticator: {
                ControlPasswordAuthenticator(passwordStore: store, accessMode: currentMode())
            },
            dispatcher: dispatcher
        )
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handler.run()
            done.signal()
        }
        pair.clientWrite("{\"id\":7,\"method\":\"events.stream\"}\n")
        pair.clientShutdownWrite()
        done.wait()
        let output = pair.clientReadAll()

        // Mode was cmuxOnly at connect; by the time the events.stream line is
        // read it is password, so the live gate denies it. A spawn-frozen
        // capture would have streamed it unauthenticated.
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        #expect(object["id"] as? Int == 7)
        #expect((object["error"] as? [String: Any])?["code"] as? String == "auth_required")
        #expect(dispatcher.snapshotEventsStream().isEmpty)
    }

    @Test func emptyAndWhitespaceLinesAreSkippedBeforeDispatch() throws {
        let pair = try HandlerSocketPair()
        let dispatcher = RecordingDispatcher { line, _ in
            ControlClientCommandOutcome(response: "R:\(line)", authenticated: false)
        }
        let output = driveHandler(
            pair: pair,
            store: makeStore(password: nil),
            accessMode: .cmuxOnly,
            dispatcher: dispatcher
        ) {
            pair.clientWrite("\n   \nreal\n")
        }
        #expect(dispatcher.snapshotProcessed().map(\.line) == ["real"])
        #expect(output == "R:real\n")
    }

    @Test func nilResponseProducesNoWriteOrPublish() throws {
        let pair = try HandlerSocketPair()
        let dispatcher = RecordingDispatcher { _, _ in
            ControlClientCommandOutcome(response: nil, authenticated: false)
        }
        let output = driveHandler(
            pair: pair,
            store: makeStore(password: nil),
            accessMode: .cmuxOnly,
            dispatcher: dispatcher
        ) {
            pair.clientWrite("fire-and-forget\n")
        }
        #expect(dispatcher.snapshotProcessed().map(\.line) == ["fire-and-forget"])
        #expect(output == "")
        #expect(dispatcher.snapshotPublished().isEmpty)
    }
}

/// Serialized: every test constructs a `SocketControlPasswordStore` whose
/// `hasConfiguredPassword(allowLazyKeychainFallback:)` consults shared keychain
/// fallback state, which parallel cases can observe mid-write.
@Suite("ControlPasswordAuthenticator", .serialized)
struct ControlPasswordAuthenticatorTests {
    private func makeStore(password: String?) -> SocketControlPasswordStore {
        let url = URL(fileURLWithPath: "/tmp/cmux-ctlsock-pwauth-\(UUID().uuidString).json")
        let store = SocketControlPasswordStore(environment: [:], fileURL: url)
        if let password {
            try? store.savePassword(password)
        }
        return store
    }

    private func authenticator(password: String?, mode: SocketControlMode) -> ControlPasswordAuthenticator {
        ControlPasswordAuthenticator(passwordStore: makeStore(password: password), accessMode: mode)
    }

    @Test func noAuthModeNeverGates() {
        let auth = authenticator(password: "p", mode: .cmuxOnly)
        let decision = auth.response(for: "anything", authenticated: false)
        #expect(decision.response == nil)
        #expect(decision.authenticated == false)
    }

    @Test func alreadyAuthenticatedNonAuthLinePasses() {
        let auth = authenticator(password: "p", mode: .password)
        let decision = auth.response(for: "list-workspaces", authenticated: true)
        #expect(decision.response == nil)
        #expect(decision.authenticated == true)
    }

    @Test func v1CorrectPassword() {
        let auth = authenticator(password: "hunter2", mode: .password)
        let decision = auth.response(for: "auth hunter2", authenticated: false)
        #expect(decision.response == "OK: Authenticated")
        #expect(decision.authenticated == true)
    }

    @Test func v1WrongPassword() {
        let auth = authenticator(password: "hunter2", mode: .password)
        let decision = auth.response(for: "auth nope", authenticated: false)
        #expect(decision.response == "ERROR: Invalid password")
        #expect(decision.authenticated == false)
    }

    @Test func v1MissingPassword() {
        let auth = authenticator(password: "hunter2", mode: .password)
        let decision = auth.response(for: "auth", authenticated: false)
        #expect(decision.response == "ERROR: Missing password. Usage: auth <password>")
        #expect(decision.authenticated == false)
    }

    @Test func v1NoConfiguredPassword() {
        let auth = authenticator(password: nil, mode: .password)
        let decision = auth.response(for: "auth whatever", authenticated: false)
        #expect(decision.response == "ERROR: Password mode is enabled but no socket password is configured in Settings.")
        #expect(decision.authenticated == false)
    }

    @Test func unauthenticatedNonJSONGetsPlainAuthRequired() {
        let auth = authenticator(password: "hunter2", mode: .password)
        let decision = auth.response(for: "list-workspaces", authenticated: false)
        #expect(decision.response == "ERROR: Authentication required — send auth <password> first")
        #expect(decision.authenticated == false)
    }

    @Test func v2AuthLoginCorrectPassword() throws {
        let auth = authenticator(password: "hunter2", mode: .password)
        let decision = auth.response(
            for: "{\"id\":7,\"method\":\"auth.login\",\"params\":{\"password\":\"hunter2\"}}",
            authenticated: false
        )
        #expect(decision.authenticated == true)
        let object = try JSONSerialization.jsonObject(with: Data((decision.response ?? "").utf8)) as! [String: Any]
        #expect(object["id"] as? Int == 7)
        #expect((object["result"] as? [String: Any])?["authenticated"] as? Bool == true)
    }

    @Test func v2AuthLoginWrongPassword() throws {
        let auth = authenticator(password: "hunter2", mode: .password)
        let decision = auth.response(
            for: "{\"id\":1,\"method\":\"auth.login\",\"params\":{\"password\":\"nope\"}}",
            authenticated: false
        )
        #expect(decision.authenticated == false)
        let object = try JSONSerialization.jsonObject(with: Data((decision.response ?? "").utf8)) as! [String: Any]
        #expect((object["error"] as? [String: Any])?["code"] as? String == "auth_failed")
    }

    @Test func v2AuthLoginMissingParams() throws {
        let auth = authenticator(password: "hunter2", mode: .password)
        let decision = auth.response(
            for: "{\"id\":2,\"method\":\"auth.login\",\"params\":{}}",
            authenticated: false
        )
        let object = try JSONSerialization.jsonObject(with: Data((decision.response ?? "").utf8)) as! [String: Any]
        #expect((object["error"] as? [String: Any])?["code"] as? String == "invalid_params")
    }

    @Test func unauthenticatedJSONCommandGetsAuthRequiredEchoingId() throws {
        let auth = authenticator(password: "hunter2", mode: .password)
        let decision = auth.response(for: "{\"id\":3,\"method\":\"system.ping\"}", authenticated: false)
        let object = try JSONSerialization.jsonObject(with: Data((decision.response ?? "").utf8)) as! [String: Any]
        #expect(object["id"] as? Int == 3)
        #expect((object["error"] as? [String: Any])?["code"] as? String == "auth_required")
    }
}
