import CmuxControlSocket
import Darwin
import Dispatch
import Foundation
import Testing

/// A connected pair standing in for an accepted control-socket connection:
/// `server` is the app's descriptor, `client` the CLI's.
private struct SocketPair {
    let server: Int32
    var client: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        server = fds[0]
        client = fds[1]
    }

    mutating func closeClient() {
        if client >= 0 { close(client) }
        client = -1
    }

    func closeAll() {
        close(server)
        if client >= 0 { close(client) }
    }
}

@Suite("A socket worker stops waiting when its client leaves")
struct ControlClientCompletionWaitTests {
    @Test("a client that hangs up frees the worker long before the call's limit")
    func clientCloseEndsTheWait() throws {
        // `cmux vm shell` gives up after 30 s and closes its connection, but a
        // VM call's worker waited its own limit (up to 17 min), holding one of
        // the control socket's 32 slots for an answer nobody reads. Enough of
        // those and every command times out until the app restarts (#48314).
        var pair = try SocketPair()
        defer { pair.closeAll() }
        let wait = ControlClientCompletionWait(clientSocket: pair.server)
        DispatchQueue.global().async { [client = pair.client] in
            // The CLI process exits: the kernel closes its end.
            close(client)
        }
        pair.client = -1
        // The limit only bounds a broken run; `.timedOut` here would mean the
        // close went unseen.
        #expect(wait.wait(timeoutSeconds: 600) == .clientClosed)
    }

    @Test("a client already gone before the wait starts is seen at once")
    func clientClosedBeforeWait() throws {
        var pair = try SocketPair()
        defer { pair.closeAll() }
        pair.closeClient()
        let wait = ControlClientCompletionWait(clientSocket: pair.server)
        #expect(wait.wait(timeoutSeconds: 60) == .clientClosed)
    }

    @Test("completion wins while the client still waits")
    func completionEndsTheWait() throws {
        let pair = try SocketPair()
        defer { pair.closeAll() }
        let wait = ControlClientCompletionWait(clientSocket: pair.server)
        DispatchQueue.global().async { wait.complete() }
        #expect(wait.wait(timeoutSeconds: 60) == .completed)
    }

    @Test("completion before the wait starts is not lost")
    func completionBeforeWait() throws {
        let pair = try SocketPair()
        defer { pair.closeAll() }
        let wait = ControlClientCompletionWait(clientSocket: pair.server)
        wait.complete()
        #expect(wait.wait(timeoutSeconds: 60) == .completed)
    }

    @Test("a client that half-closes its write side still gets its answer")
    func halfCloseKeepsWaiting() throws {
        // `printf '{...}' | nc -U` style clients shut down writing after the
        // request and still read the reply; that is not leaving.
        var pair = try SocketPair()
        defer { pair.closeAll() }
        shutdown(pair.client, SHUT_WR)
        let wait = ControlClientCompletionWait(clientSocket: pair.server)
        // A zero limit reports the state the kernel already holds, without
        // waiting on the clock.
        #expect(wait.wait(timeoutSeconds: 0) == .timedOut)
        // The same descriptor still reports a later full close.
        pair.closeClient()
        #expect(wait.wait(timeoutSeconds: 600) == .clientClosed)
    }

    @Test("a zero limit still reports a client that already left")
    func zeroLimitSeesClose() throws {
        var pair = try SocketPair()
        defer { pair.closeAll() }
        pair.closeClient()
        #expect(ControlClientCompletionWait(clientSocket: pair.server).wait(timeoutSeconds: 0) == .clientClosed)
    }

    @Test("a pipelined request does not end the wait")
    func pipelinedDataKeepsWaiting() throws {
        let pair = try SocketPair()
        defer { pair.closeAll() }
        let byte: [UInt8] = [0x7B]
        _ = byte.withUnsafeBytes { write(pair.client, $0.baseAddress, 1) }
        let wait = ControlClientCompletionWait(clientSocket: pair.server)
        #expect(wait.wait(timeoutSeconds: 0) == .timedOut)
    }

    @Test("a non-finite limit neither traps nor ends the wait early")
    func nonFiniteLimits() throws {
        let pair = try SocketPair()
        defer { pair.closeAll() }
        #expect(ControlClientCompletionWait(clientSocket: pair.server).wait(timeoutSeconds: .nan) == .timedOut)
        let done = ControlClientCompletionWait(clientSocket: pair.server)
        done.complete()
        #expect(done.wait(timeoutSeconds: .infinity) == .completed)
    }

    @Test("an in-process call with no client socket waits for completion or its limit")
    func noClientSocket() {
        let wait = ControlClientCompletionWait(clientSocket: nil)
        #expect(wait.wait(timeoutSeconds: 0) == .timedOut)
        let done = ControlClientCompletionWait(clientSocket: nil)
        DispatchQueue.global().async { done.complete() }
        #expect(done.wait(timeoutSeconds: nil) == .completed)
    }
}
