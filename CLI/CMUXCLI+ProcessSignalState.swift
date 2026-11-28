import Darwin

/// Signals a CLI command may leave ignored while it runs: pipe handling at
/// startup, and the SIGWINCH `DispatchSource` monitors of the SSH and VM PTY
/// bridges. An ignored disposition survives `exec`, and an interactive agent
/// must own its terminal-size and pipe signals itself.
let cliChildLaunchDefaultDispositionSignals: [Int32] = [SIGPIPE, SIGWINCH, SIGTTOU]

/// Returns the calling thread and this process to the signal state a shell
/// hands an interactive program, immediately before an `exec`.
///
/// CLI commands run on Swift concurrency threads. On macOS those threads
/// carry a nearly full signal mask, and `execve` gives the new image the mask
/// of the thread that called it. A Codex or Claude Code process resumed by
/// `cmux restore` therefore started with SIGWINCH blocked, never received a
/// resize event, and kept painting at its startup width (#12681).
func cliResetInheritedSignalStateForExec() {
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    _ = pthread_sigmask(SIG_SETMASK, &emptyMask, nil)
    for signalNumber in cliChildLaunchDefaultDispositionSignals {
        _ = signal(signalNumber, SIG_DFL)
    }
}
