import Darwin
import Foundation

/// A locally-allocated PTY pair for running `tmux -CC` control mode directly
/// (the ``RemoteTmuxHost/local`` endpoint).
///
/// tmux control mode requires a controlling terminal — on a bare pipe the
/// client dies with "tcgetattr failed". Over SSH, `ssh -tt` supplies that tty
/// on the remote side while cmux's side stays plain pipes; locally, cmux
/// supplies it itself: the child gets the pty slave as stdin/stdout, and cmux
/// reads/writes the master. stderr stays a separate pipe so failure
/// classification ("no server running", the missing-tmux sentinel, …) keeps
/// working — a pty would merge stderr into the control stream (the reason the
/// e2e ssh shim only wraps `-tt` invocations in `script(1)`).
///
/// The slave is put in raw mode *before* launch so no cooked-tty translation
/// can touch the control stream in the window before tmux configures the tty
/// itself: no echo (a written command must not bounce back into the parser)
/// and no ONLCR (`\n` → `\r\n`; the parser tolerates stray `\r` from `ssh -tt`,
/// but raw keeps the local stream byte-exact).
struct RemoteTmuxLocalPTY {
    /// Reads tmux's control-stream output; owns the master descriptor.
    let masterReadHandle: FileHandle
    /// Writes commands to tmux; owns a `dup` of the master so the reader's and
    /// writer's independent `close()`s can never double-close one descriptor.
    let masterWriteHandle: FileHandle
    /// The child's stdin/stdout. Owned here; the parent must close it right
    /// after launch (the spawned child holds its own copy) so master reads see
    /// EIO — the pty's EOF — when the child exits.
    let slaveHandle: FileHandle

    static func open() throws -> RemoteTmuxLocalPTY {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw RemoteTmuxError.launchFailed("openpty: \(String(cString: strerror(errno)))")
        }

        var tio = termios()
        if tcgetattr(slave, &tio) == 0 {
            cfmakeraw(&tio)
            _ = tcsetattr(slave, TCSANOW, &tio)
        }
        // A sane default client size for the brief pre-attach window; once the
        // mirror is live, cmux drives sizing with `refresh-client -C` claims and
        // a control client never becomes tmux's "latest" client anyway.
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &size)

        // Keep the parent-side descriptors out of every other child cmux spawns:
        // a leaked master in an unrelated long-lived child would hold the pty
        // open and delay EOF. (Foundation dup2s the slave for this child itself.)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let writeFD = dup(master)
        guard writeFD >= 0 else {
            let error = String(cString: strerror(errno))
            close(master)
            close(slave)
            throw RemoteTmuxError.launchFailed("dup pty master: \(error)")
        }
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        return RemoteTmuxLocalPTY(
            masterReadHandle: FileHandle(fileDescriptor: master, closeOnDealloc: true),
            masterWriteHandle: FileHandle(fileDescriptor: writeFD, closeOnDealloc: true),
            slaveHandle: FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        )
    }
}
