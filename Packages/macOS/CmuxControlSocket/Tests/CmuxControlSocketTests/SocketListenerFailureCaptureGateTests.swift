import Darwin
import Testing

@testable import CmuxControlSocket

@Suite struct SocketListenerFailureCaptureGateTests {
    @Test func capturesEachDistinctKeyOncePerEpisode() {
        let gate = SocketListenerFailureCaptureGate()
        #expect(gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "create_lock_directory",
            path: "/tmp/a.sock",
            errnoCode: EIO
        ))
        // A wedged machine retries the identical failure on every wake; the
        // second and later identical failures stay breadcrumb-only.
        #expect(!gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "create_lock_directory",
            path: "/tmp/a.sock",
            errnoCode: EIO
        ))
        // A different stage, path, or errno is a distinct failure.
        #expect(gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "bind",
            path: "/tmp/a.sock",
            errnoCode: EIO
        ))
        #expect(gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "create_lock_directory",
            path: "/tmp/b.sock",
            errnoCode: EIO
        ))
        #expect(gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "create_lock_directory",
            path: "/tmp/a.sock",
            errnoCode: EACCES
        ))
        #expect(gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "create_lock_directory",
            path: "/tmp/a.sock",
            errnoCode: nil
        ))
    }

    @Test func successfulListenerStartOpensANewEpisode() {
        let gate = SocketListenerFailureCaptureGate()
        #expect(gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "bind",
            path: "/tmp/a.sock",
            errnoCode: EADDRINUSE
        ))
        #expect(!gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "bind",
            path: "/tmp/a.sock",
            errnoCode: EADDRINUSE
        ))

        gate.listenerDidStart()

        // The listener recovered; a later identical failure is a new incident.
        #expect(gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "bind",
            path: "/tmp/a.sock",
            errnoCode: EADDRINUSE
        ))
    }

    @Test func pathMissingIsBreadcrumbOnlyWhenSuppressed() {
        let gate = SocketListenerFailureCaptureGate(capturesPathMissingFailures: false)
        // Dev-machine cleanup scripts delete /tmp debug sockets and the path
        // monitor self-heals; that expected state never escalates to a capture.
        #expect(!gate.shouldCapture(
            message: SocketListenerFailureCaptureGate.pathMissingMessage,
            stage: "path_monitor",
            path: "/tmp/cmux-debug-main.sock",
            errnoCode: nil
        ))
        // Other failures still capture on debug builds.
        #expect(gate.shouldCapture(
            message: "socket.listener.start.failed",
            stage: "bind",
            path: "/tmp/cmux-debug-main.sock",
            errnoCode: EADDRINUSE
        ))
    }

    @Test func pathMissingCapturesOncePerEpisodeWhenNotSuppressed() {
        let gate = SocketListenerFailureCaptureGate()
        #expect(gate.shouldCapture(
            message: SocketListenerFailureCaptureGate.pathMissingMessage,
            stage: "path_monitor",
            path: "/tmp/a.sock",
            errnoCode: nil
        ))
        #expect(!gate.shouldCapture(
            message: SocketListenerFailureCaptureGate.pathMissingMessage,
            stage: "path_monitor",
            path: "/tmp/a.sock",
            errnoCode: nil
        ))
    }
}
