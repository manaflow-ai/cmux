import Foundation

/// Trust boundary for program-originated OSC 52 and Kitty clipboard writes.
/// A missing process result is untrusted; user paste and interactive copy
/// actions do not use this policy.
nonisolated struct TerminalClipboardWritePolicy {
    private let remoteTransports: Set<String> = [
        "ssh", "autossh", "mosh", "mosh-client", "telnet", "rlogin",
        // A multiplexer hides the program behind its client process, so the
        // foreground executable cannot prove that its active pane is local.
        "tmux", "screen", "zellij",
    ]

    func canCheckProcess(isFocused: Bool, isLocalDaemon: Bool, isRemoteTerminal: Bool) -> Bool {
        isFocused && isLocalDaemon && !isRemoteTerminal
    }

    func allowsSilentWrite(isFocused: Bool, isLocalDaemon: Bool, isRemoteTerminal: Bool,
                           foregroundExecutable: String?) -> Bool {
        guard canCheckProcess(isFocused: isFocused, isLocalDaemon: isLocalDaemon,
                              isRemoteTerminal: isRemoteTerminal),
              var executable = foregroundExecutable.map({ ($0 as NSString).lastPathComponent.lowercased() }),
              !executable.isEmpty else { return false }
        if executable.hasPrefix("-") { executable.removeFirst() }
        return !remoteTransports.contains(executable)
    }
}
