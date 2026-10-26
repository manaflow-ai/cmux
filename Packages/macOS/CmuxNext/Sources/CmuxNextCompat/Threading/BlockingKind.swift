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
    /// A synchronous XPC or Mach send that waits for the reply.
    case ipcReply = "ipc-reply"
    /// A wait for a child process to exit.
    case processWait = "process-wait"
    /// Starting a child process (`Process.run`, `posix_spawn`, `fork`): it copies or maps the parent's
    /// address space and waits for the kernel, which took 807 ms on the main thread (screen.close,
    /// 2026-10-24).
    case processSpawn = "process-spawn"
    /// A ``Mutex`` wait on the main thread that took longer than
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

    /// The longest contended ``Mutex`` wait the main thread may do before the detector records
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
