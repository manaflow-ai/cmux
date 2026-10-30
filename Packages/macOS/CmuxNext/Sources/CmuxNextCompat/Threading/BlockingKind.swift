/// The kind of wait (or of long CPU work) a blocking call does, as the main-thread blocking detector names it.
///
/// The detector (``blockingCall(_:fileID:line:_:)``) is cmux's copy of Chrome's
/// `base::ScopedBlockingCall` and `base::ThreadRestrictions`: the main thread never waits on
/// disk, a socket, another thread, another process or a child's exit
/// (plans/cmux-next/threading-model.md). The raw values are the names the debug log and the
/// opt-in hang reports use, so they never change.
public enum BlockingKind: String, Sendable, CaseIterable {
    /// A file system read, write, stat, directory listing or move.
    case fileIO = "file-io"
    /// A synchronous read or receive on a socket or pipe.
    case socketRead = "socket-read"
    /// A synchronous write or send on a socket or pipe (it waits while the peer's buffer is full).
    case socketWrite = "socket-write"
    /// A wait on a semaphore, a dispatch group, a condition or a `DispatchQueue.sync`.
    case syncWait = "sync-wait"
    /// A synchronous Mach send, or a framework call over one (ServiceManagement), that waits for the reply. A
    /// synchronous XPC send is ``xpcReply``.
    case ipcReply = "ipc-reply"
    /// A wait for a child process to exit.
    case processWait = "process-wait"
    /// Starting a child process (`Process.run`, `posix_spawn`, `fork`): it copies or maps the parent's
    /// address space and waits for the kernel, which took 807 ms on the main thread (screen.close,
    /// 2026-10-24).
    case processSpawn = "process-spawn"
    /// A ``Mutex`` wait on the main thread or in a `BackgroundWork` lane item that took longer than
    /// ``BlockingKind/lockWaitLimitNanos`` (a contended lock: the priority-inversion case).
    case lockWait = "lock-wait"
    /// A synchronous system framework call that waits for a daemon, another app, the window server or
    /// the network (Security, Accessibility, host resolution, window lists, LaunchServices).
    case systemCall = "system-call"
    /// A sleep (`usleep`, `Thread.sleep`): the thread waits on purpose.
    case sleep
    /// Any blocking seam inside a job of a lane that must not block (BackgroundWork's `.cpu` lane,
    /// ``BlockingContext/cpuLane``), off the main thread: that lane is sized to the cores, so a wait there holds a
    /// core's slot idle. Run the job on `.files` or `.system` (Chrome's task without `MayBlock`).
    case wrongLane = "wrong-lane"
    /// Long CPU work over an input above its size gate: decoding a large JSON document or image, compressing or
    /// decompressing, or a regular-expression search over a long text (``cpuIntensiveCall(size:limit:fileID:line:_:)``
    /// and the seams in CPUIntensive+Blocking.swift). It waits on nothing, but it holds the thread as long as a disk
    /// read does. Only the main thread disallows it, as Chrome's UI thread disallows long CPU work
    /// (`DisallowUnresponsiveTasks()` also clears `AssertLongCPUWorkAllowed()`, base/threading/thread_restrictions.h):
    /// on a lane or the pool it is the work they are for, so it is never a pool or wrong-lane site.
    case cpuIntensive = "cpu-intensive"
    /// A file system metadata call (`stat`, `lstat`, `access`, `realpath`, `chmod`, `mkdir`, `rmdir`, `rename`,
    /// `unlink`): it waits for the volume, which on a network, FUSE or sleeping disk takes seconds.
    case fsMetadata = "fs-metadata"
    /// A SQLite open, prepare, step, exec, backup step or close: it reads and writes the database file and waits out
    /// another connection's lock for the busy timeout.
    case sqlite
    /// A `waitpid` or `waitid` that waits for a child to exit (without `WNOHANG`).
    case processReap = "process-reap"
    /// A kernel or directory query (`sysctl`, `proc_pidinfo`, `proc_pidpath`, `proc_listpids`, `getpwuid`):
    /// usually short, but it waits on a kernel lock or for opendirectoryd.
    case systemQuery = "system-query"
    /// The main thread awaits a BackgroundWork item stated below `.userBlocking` while a person's input action
    /// is open (``recordAwaitedLowPriorityWork(fileID:line:)``): the action's result waits behind lower-priority
    /// work. The main thread does not block (it awaits), so this kind is recorded only, never a trap, and its
    /// site counts awaits without time. Chrome's rule: work a person waits for is `USER_BLOCKING`
    /// (base/task/task_traits.h).
    case priorityInversion = "priority-inversion"
    /// A synchronous call into a C library that reads files or waits inside it, behind a C interface no Swift seam
    /// can see into: libghostty's config load (`ghostty_config_load_default_files`, `ghostty_config_load_file`,
    /// `ghostty_config_load_recursive_files`, and `ghostty_config_finalize`, which reads the theme file), through
    /// ``blockingFFI(fileID:line:_:)``. Chrome marks the same calls into third-party code with a
    /// `ScopedBlockingCall` at the call (base/threading/scoped_blocking_call.h).
    case ffi
    /// A synchronous XPC send that waits for the reply (`xpc_connection_send_message_with_reply_sync`, through
    /// ``blockingXPCSendWithReply(_:_:fileID:line:)``): the thread waits for a daemon or an XPC service for as long as
    /// it takes to answer.
    /// Chrome makes no synchronous cross-process call on its UI thread: a sync Mojo call needs a
    /// `ScopedAllowBaseSyncPrimitivesOutsideBlockingScope`, whose friends are listed exceptions
    /// (base/threading/thread_restrictions.h).
    case xpcReply = "xpc-reply"

    /// Whether a site of this kind is recorded only, in every mode: ``lockWait`` (its measured wait includes the
    /// main thread's own scheduling delay) and ``priorityInversion`` (an await, not a wait).
    public var isRecordOnly: Bool {
        self == .lockWait || self == .priorityInversion
    }

    /// Whether the kind waits for another thread or process to act: a semaphore, a group, a condition or a
    /// `DispatchQueue.sync` (``syncWait``), a contended ``Mutex`` past ``lockWaitLimitNanos`` (``lockWait``) or a
    /// synchronous reply (``ipcReply``, ``xpcReply``). These are Chrome's base sync primitives (`WaitableEvent`,
    /// `ConditionVariable`, a sync Mojo call): a `BackgroundWork` lane may wait on the disk or a socket, but one
    /// of these in a lane item records a ``BlockingContext/laneSync`` site, as Chrome runs a `MayBlock()` task
    /// without `WithBaseSyncPrimitives()` under `ScopedDisallowBaseSyncPrimitives`
    /// (base/task/thread_pool/task_tracker.cc). A dedicated thread or queue may wait on them.
    public var isSyncPrimitive: Bool {
        switch self {
        case .syncWait, .lockWait, .ipcReply, .xpcReply:
            true
        case .fileIO, .socketRead, .socketWrite, .processWait, .processSpawn, .systemCall, .sleep, .wrongLane,
             .cpuIntensive, .fsMetadata, .sqlite, .processReap, .systemQuery, .priorityInversion, .ffi:
            false
        }
    }

    /// The longest contended ``Mutex`` wait the main thread or a lane item may do before the detector records
    /// it (2 ms, lead decision 2026-10-24: a short critical section is allowed, as Chrome allows
    /// `base::Lock`; a wait this long means a lower-priority thread holds the lock).
    public static let lockWaitLimitNanos: UInt64 = 2_000_000

    /// The largest JSON or property list input, in bytes, the decode seams take on the main thread without a
    /// ``cpuIntensive`` site (64 KiB: about a millisecond of Codable decoding, a sixteenth of a 60 Hz frame).
    public static let cpuIntensiveJSONBytes = 64 * 1024
    /// The largest decoded image, in bytes of 8-bit RGBA (4 per pixel), ``blockingImageDecode(_:at:fileID:line:)``
    /// and ``blockingImageThumbnail(_:at:options:fileID:line:)`` take on the main thread without a site (256 KiB:
    /// 256 by 256 pixels). A decode costs by its pixels, not its encoded bytes: a 2880 by 1800 screenshot is a PNG of
    /// about 200 KiB and 20 MB of pixels. Chrome bounds its image decodes the same way, by decoded bytes
    /// (`ImageDecoder`'s `max_decoded_bytes`, third_party/blink/renderer/platform/image-decoders/image_decoder.h).
    public static let cpuIntensiveImagePixelBytes = 256 * 1024
    /// The largest uncompressed size, in bytes, the compression seams take on the main thread without a site
    /// (64 KiB): the input of ``Foundation/Data/blockingCompress(using:fileID:line:)``, the output of
    /// ``Foundation/Data/blockingDecompress(using:expectedSize:fileID:line:)``.
    public static let cpuIntensiveCompressionBytes = 64 * 1024
    /// How many times its compressed size ``Foundation/Data/blockingDecompress(using:expectedSize:fileID:line:)``
    /// takes the output to be when the caller does not know it (8: lzfse and zlib on text and JSON).
    public static let cpuIntensiveCompressionRatio = 8
    /// The longest searched range, in UTF-16 code units, the regular-expression seams take on the main thread
    /// without a site (32 Ki units: a pattern that backtracks costs much more per unit than a decode).
    public static let cpuIntensiveRegexUTF16 = 32 * 1024
}
