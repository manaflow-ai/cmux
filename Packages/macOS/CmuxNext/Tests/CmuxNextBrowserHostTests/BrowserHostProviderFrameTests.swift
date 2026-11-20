import CmuxNextBrowser
import CmuxNextBrowserAutomation
@testable import CmuxNextBrowserHost
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// Review 2 of pl-main-bc (finding 6): 5474e1c445e handled each host frame on a display frame, so every
/// CDP command and driver call of an agent waited for a frame tick (up to the frame scheduler's 100 ms
/// stall timeout while the display sleeps); the review-1 fix handles each frame as it is read. The
/// provider dials a stand-in host here: a call's reply leaves with no display frame.
///
/// `FrameScheduler.app` is the one frame scheduler of the test process, and the suites of a run share that process:
/// a window of a suite that runs beside this one ticks it too. The first form of this test compared its count over
/// one call and failed whenever a window suite ran beside it (2026-11-10, aws-m4pro-9: green alone, red beside
/// CmdTTabListReadersTests, `frames` 1 against 0); CI runs this target in one process with CmuxNextAppTests suites.
/// So the proof is over a run of calls: ONE call that is answered while the scheduler delivered no frame shows
/// that a reply needs none. A provider that handles host frames on this scheduler's frames again gets at least one
/// frame before each reply, so no call of the run is free of one, however many suites run beside it. As before,
/// the test does not see a queue on another scheduler (5474e1c445e's was on the app's main-work scheduler).
@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserHostProviderFrameTests {
    /// The most calls one run asks: it ends at the first reply with no frame between the call and the reply.
    private static let calls: UInt64 = 40

    @Test func aCallIsAnsweredWithoutADisplayFrame() async throws {
        let path = "/tmp/cmux-bh-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let host = try StandInHost(listeningAt: path)
        let sources = StandInSources(socketPath: path)
        // The provider's own dial (ProviderConnection.dial): the listener's peer is this process.
        let provider = BrowserHostProvider(identity: ProviderIdentity(providerID: "test", installID: "test-install"),
                                           credentials: sources, tabs: sources, access: sources, driver: nil,
                                           relay: sources, marking: sources)
        provider.start()
        try await host.accept()
        let hello = try await host.next { if case .hello = $0 { true } else { false } }
        #expect(hello.tag == "hello")
        await host.send(.helloAck(agentBundle: "", agentBundleSHA: "sha"))
        var asked: UInt64 = 0
        var answeredWithoutFrame = false
        for id in 7..<(7 + Self.calls) where !answeredWithoutFrame {
            let framesBefore = FrameScheduler.app.frames
            // A call that names no tab is refused by the app itself, at once (no driver, no page).
            await host.send(.call(id: id, method: "cookies.get", params: .object([:])))
            let reply = try await host.next { if case .result(let answered, _, _) = $0 { answered == id } else { false } }
            asked += 1
            guard case .result(_, let result, let error) = reply else { break }
            #expect(result == nil)
            #expect(error != nil)
            answeredWithoutFrame = FrameScheduler.app.frames == framesBefore
        }
        print("browser host frame test: a reply with no display frame after \(asked) call(s): \(answeredWithoutFrame)")
        #expect(answeredWithoutFrame, "each of \(asked) replies came with a display frame between its call and the reply: a reply waits for a frame")
        provider.stop()
        withExtendedLifetime(sources) {}
        await host.close()
    }
}

/// The browser host's end: a listening socket the provider dials, then the accepted link. Reads and
/// accepts block on the actor's executor (off the main actor, where the provider runs); each is
/// bounded by the socket's receive timeout, so a missing reply fails the test instead of hanging it.
private actor StandInHost {
    private let path: String
    private let listener: Int32
    private var fd: Int32 = -1
    private var decoder = ProviderFrameDecoder()

    init(listeningAt path: String) throws {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw StandInHostError.socket(errno: errno) }
        self.path = path
        listener = socketFD
        // accept() honors the receive timeout: a provider that never dials fails the test, never hangs it.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketFD)
            throw StandInHostError.socket(errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(socketFD, 1) == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw StandInHostError.socket(errno: code)
        }
    }

    /// Takes the provider's connection.
    func accept() throws {
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else { throw StandInHostError.socket(errno: errno) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        _ = setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = accepted
    }

    /// The next frame from the app that `matches`, skipping the others (tab announcements).
    func next(_ matches: @Sendable (ProviderFrame) -> Bool) throws -> ProviderFrame {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            while let frame = try decoder.next() {
                if matches(frame) { return frame }
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { throw StandInHostError.readEnded(errno: count < 0 ? errno : 0) }
            buffer.withUnsafeBytes { decoder.push(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
    }

    func send(_ frame: ProviderFrame) {
        guard let bytes = try? ProviderCodec.encode(frame) else { return }
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        Darwin.close(listener)
        unlink(path)
    }
}

private enum StandInHostError: Error {
    /// Creating, binding, listening on or accepting from the socket failed.
    case socket(errno: Int32)
    /// The app closed the link, or no frame came within the receive timeout (`EAGAIN`).
    case readEnded(errno: Int32)
}

/// Every source the provider reads, empty: no tabs, no relay, and credentials naming the stand-in
/// host's socket and this process (the listener, so the dialed socket's peer).
@MainActor
private final class StandInSources: ProviderCredentialsSource, ProviderTabSource, ProviderAccessSource, ProviderDevToolsRelay,
    ProviderAgentMarking {
    private let socketPath: String

    init(socketPath: String) { self.socketPath = socketPath }

    func providerCredentials() async -> ProviderCredentials? {
        ProviderCredentials(socketPath: socketPath, secret: ProviderSecret("test-secret"), hostPID: getpid())
    }

    var providerTabs: [ProviderTab] { [] }

    func access(forTab targetID: String) -> ProviderTabAccess {
        ProviderTabAccess(extensionHostAccess: false, userOverride: false, extensions: [])
    }

    func prepareRelay(targetID: String) async -> Bool { false }
    func startRelay(targetID: String, onMessage: @escaping (String) -> Void, onEnd: @escaping () -> Void) -> Bool { false }
    func send(targetID: String, message: String) -> CEFDevToolsRawSend { .noBrowser }
    func stopRelay(targetID: String) {}
    func agentWillDrive(targetID: String) {}
}
