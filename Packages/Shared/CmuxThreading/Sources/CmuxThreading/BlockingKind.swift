/// What a shared package's blocking call waits on, as the app's blocking detector names it.
///
/// The cases and raw values are those of the app's own kinds (CmuxNextCompat's `BlockingKind`) for the waits code
/// below the app does; the app's hook (``BlockingCallHook``) records a call under the app kind of the same name. The
/// raw values are the names the debug log and the opt-in hang reports use, so they never change. Chrome marks the
/// same waits with one `base::ScopedBlockingCall` (base/threading/scoped_blocking_call.h) in every component.
public enum BlockingKind: String, Sendable, CaseIterable {
    /// A file system read, write, directory listing or move.
    case fileIO = "file-io"
    /// A file system metadata call (`stat`, `lstat`, `access`, `realpath`, `mkdir`, `rename`, `unlink`): it waits for
    /// the volume, which on a network, FUSE or sleeping disk takes seconds.
    case fsMetadata = "fs-metadata"
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
    /// Starting a child process (`Process.run`, `posix_spawn`): it maps the parent's address space and waits for the
    /// kernel.
    case processSpawn = "process-spawn"
    /// A `waitpid` or `waitid` that waits for a child to exit (without `WNOHANG`).
    case processReap = "process-reap"
    /// A synchronous system framework call that waits for a daemon or the network (Security, host resolution).
    case systemCall = "system-call"
    /// A kernel or directory query (`sysctl`, `proc_pidinfo`, `getpwuid`).
    case systemQuery = "system-query"
    /// A SQLite open, prepare, step, exec or close: it reads and writes the database file and waits out another
    /// connection's lock for the busy timeout.
    case sqlite
    /// A sleep (`usleep`, `Thread.sleep`): the thread waits on purpose.
    case sleep
}
