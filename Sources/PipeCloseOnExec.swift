import Foundation

/// `Pipe` descriptors that must not leak into children.
///
/// A plain `Pipe()` is inheritable: every PTY child cmux spawns afterwards (terminal
/// shells, tmux servers) picks up both ends of every probe pipe that happens to be
/// open, keeps the write end alive so the parent never sees EOF, and holds the
/// descriptors for as long as the shell lives. `Process` dup2s the ends it hands
/// the child onto stdout/stderr itself, and dup2 clears the flag on the new
/// descriptor, so marking the originals close-on-exec costs nothing.
extension Pipe {
    /// A pipe whose descriptors are closed across `exec` in every child.
    static func closeOnExec() -> Pipe {
        let pipe = Pipe()
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0 else { continue }
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
        return pipe
    }

    /// Release both descriptors now rather than whenever the handles deallocate.
    ///
    /// `Process` already closes the child-side end after launch and `FileHandle`
    /// ignores a second close, so this is safe to call unconditionally once the
    /// read side has been drained.
    func closeBothEnds() {
        try? fileHandleForReading.close()
        try? fileHandleForWriting.close()
    }
}
