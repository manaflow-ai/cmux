#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextTrace
import Darwin
import Foundation

/// cmux's end of the wire to one Chromium host: two stream socket pairs, one
/// per direction. Frames to the host leave on ``send(_:)``
/// with one `write` on a non-blocking descriptor, at once: no frame waits for
/// a display tick, as Chrome sends input to the renderer as it comes and the
/// renderer aligns it to its frames. Frames from the host are read by a
/// thread of the connection's own, blocked in `read` on a second descriptor,
/// and arrive as ``frames``.
///
/// The reader is a thread, not a `DispatchSource` read source: it holds only
/// the ``ChromiumHostWireState`` (so a connection dropped without ``close()``
/// still deinits), it wakes in `read` the moment the host writes, with no
/// queue hop before the frame is decoded, and EOF ends it with no source to
/// cancel. One thread per running host; it ends with the host's wire.
///
/// Two pairs, because a socket's file status flags are shared by every
/// descriptor of it, and macOS ignores `MSG_DONTWAIT` on Unix sockets (checked
/// 2026-10-23): one socket cannot be written non-blocking from the main actor
/// and read blocking from a thread.
///
/// Both descriptors and the outbox are owned by one `Mutex` (the lock
/// carve-out: a short critical section around an append to the outbox, or a
/// fold into a waiting frame, and at most one non-blocking `write`, called
/// synchronously on every input event, where an actor would add a hop). The reader closes its descriptor under the lock after EOF;
/// ``close()`` shuts it down under the same lock only while it is open, so no
/// side ever touches a closed number the system may have reused. The
/// descriptors live in a ``ChromiumHostWireState`` that the reader thread
/// holds instead of the connection, so a connection dropped without
/// ``close()`` still deinits: its `deinit` closes the wire, the host reads EOF
/// and the reader ends.
///
/// Back-pressure. The kernel send buffer is ``sendBuffer``. When a host that
/// is busy or has stopped reading fills it, frames wait in a
/// ``ChromiumHostInputOutbox`` (pointer moves latest-wins, wheel deltas
/// summed, discrete frames in order) and a writable `DispatchSource` flushes
/// them when the socket takes more: a pointer flood never ends the
/// connection. More than ``ChromiumHostInputOutbox/discreteLimit`` waiting
/// discrete frames or ``ChromiumHostInputOutbox/byteLimit`` waiting bytes, a
/// failed socket, or a full socket that takes nothing for
/// ``ChromiumHostWireState/stallLimit`` (the host is stuck) ends it (its owner
/// ends the host).
/// The stream holds at most ``frameBacklog`` unread frames from the host: a
/// host that floods it is ended the same way.
nonisolated final class ChromiumHostConnection: Sendable {
    /// Bytes the kernel may hold for the host: about 4,000 input frames.
    static let sendBuffer: Int32 = 256 * 1024
    /// Frames from the host the main actor has not read yet; more ends the connection.
    static let frameBacklog = 4_096

    let frames: AsyncStream<ChromiumHostFrame>
    private let state: ChromiumHostWireState
    /// Takes one `cef.host_input` instant per frame written (tests pass one on their own trace runtime).
    private let signposter: Signposter
    /// Takes each pointer frame's flow-out while the `input` category records (task p09-observability-104).
    private let trace: TraceRuntime
    /// This process, in the flow ids it shares with the host (``ChromiumHostFrame/inputFlow(appPID:)``).
    private let appPID: UInt32

    /// Takes ownership of both descriptors: `readFD` carries frames from the
    /// host, `writeFD` frames to it. ``close()`` (or the host's EOF) closes them.
    /// `clock` times the stall check; tests pass a manual one.
    init(
        readFD: Int32,
        writeFD: Int32,
        signposter: Signposter = Signposter.cef,
        trace: TraceRuntime = .shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.signposter = signposter
        self.trace = trace
        appPID = UInt32(bitPattern: getpid())
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        var size = Self.sendBuffer
        // SAFETY: setsockopt reads the one Int32 `size` holds, the length given, during the call.
        _ = unsafe setsockopt(writeFD, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        for fd in [readFD, writeFD] {
            var noSigPipe: Int32 = 1
            // SAFETY: as above, for `noSigPipe`.
            _ = unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        let state = ChromiumHostWireState(readFD: readFD, writeFD: writeFD, clock: clock)
        self.state = state
        let (stream, continuation) = AsyncStream<ChromiumHostFrame>.makeStream(bufferingPolicy: .bufferingOldest(Self.frameBacklog))
        frames = stream
        // The thread holds the state, never the connection: see the type's doc.
        let thread = Thread { state.readFrames(fd: readFD, into: continuation) }
        thread.name = "com.cmuxterm.chromium-host.read"
        // The page's surface, address and title arrive here: what the person sees next.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        close()
    }

    /// A frame's payload is over ``ChromiumHostFrame/maxPayload``: the host
    /// would refuse it and end, so it is never written. The caller checks
    /// first (``ChromiumHostSession/open(_:)`` refuses such a URL).
    static func fits(_ frame: ChromiumHostFrame) -> Bool {
        frame.payload.count <= ChromiumHostFrame.maxPayload
    }

    /// Writes one frame now, or queues it behind frames a full socket has not
    /// taken. False when the host is gone, or has stopped reading with the
    /// outbox full (then the connection is closed and nothing more is sent),
    /// or when the frame does not ``fits(_:)`` (nothing is written and the
    /// connection stays).
    /// An accepted input frame (``ChromiumHostFrame/Kind/traceInput``) is one `cef.host_input` instant with its kind,
    /// and a pointer frame, while a recording takes `input`, a `cef.host_input` flow-out whose flow the host's
    /// dispatch of the frame flows in to (task p09-observability-104).
    @discardableResult
    func send(_ frame: ChromiumHostFrame) -> Bool { // perf-hot: 5us cef-host-input (every forwarded input event)
        guard Self.fits(frame) else { return false }
        let sent = state.send(frame)
        guard sent, let input = frame.kind?.traceInput else { return sent }
        signposter.cefHostInput(input)
        if trace.isEnabled(categoryBit: SignpostCategory.input.traceBit), let flow = frame.inputFlow(appPID: appPID) {
            trace.flowOut(.cefHostInput, flow: flow, arg0: UInt64(frame.rawKind))
        }
        return sent
    }

    /// What waits for the socket.
    var backlog: ChromiumHostWireBacklog { state.backlog }

    /// Ends the connection: the write descriptor closes (the host reads EOF)
    /// and the reader is woken with EOF and closes its own descriptor.
    func close() {
        state.close()
    }

    /// Returns once the reader thread has closed its descriptor (its last
    /// step before it ends); at once when it has.
    func readerEnded() async {
        await state.readerEnded()
    }

    /// The connection ended because the host broke the wire (a bad frame, a
    /// flood of frames, a full outbox, a socket that stalled), not because the host closed it.
    var endedByProtocolError: Bool { state.endedByProtocolError }
}

nonisolated extension ChromiumHostFrame.Kind {
    /// The `cef.host_input` kind of an input frame cmux sends; nil for every other frame (navigation, geometry,
    /// focus, ping, stats, quit, the text input watch, gestures and the host's replies), which records no instant.
    var traceInput: Signposter.CEFHostInputKind? {
        switch self {
        case .mouse: .mouse
        case .wheel: .wheel
        case .key: .key
        case .edit: .edit
        case .ime: .ime
        case .navigate, .geometry, .focus, .ping, .stats, .quit, .textInputWatch, .gesture,
             .ready, .context, .address, .title, .pong, .statsReply, .error, .rendererGone, .textInputState, .inputPresented: nil
        }
    }
}
#endif
