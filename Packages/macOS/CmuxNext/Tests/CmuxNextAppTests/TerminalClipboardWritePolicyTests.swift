import Testing
@testable import CmuxNextApp

@Suite("Terminal clipboard write policy")
struct TerminalClipboardWritePolicyTests {
    private let policy = TerminalClipboardWritePolicy()

    @Test func focusedProvenLocalProgramMayWriteSilently() {
        #expect(policy.allowsSilentWrite(isFocused: true, isLocalDaemon: true,
                                         isRemoteTerminal: false, foregroundExecutable: "/bin/zsh"))
    }

    @Test func backgroundProgramMustAsk() {
        #expect(!policy.allowsSilentWrite(isFocused: false, isLocalDaemon: true,
                                          isRemoteTerminal: false, foregroundExecutable: "/bin/zsh"))
    }

    @Test func remoteDaemonAndRemoteProjectionMustAsk() {
        #expect(!policy.allowsSilentWrite(isFocused: true, isLocalDaemon: false,
                                          isRemoteTerminal: false, foregroundExecutable: "/bin/zsh"))
        #expect(!policy.allowsSilentWrite(isFocused: true, isLocalDaemon: true,
                                          isRemoteTerminal: true, foregroundExecutable: "/bin/zsh"))
    }

    @Test(arguments: ["ssh", "/usr/bin/autossh", "mosh", "mosh-client", "telnet", "rlogin", "tmux", "screen", "zellij"])
    func nestedRemoteTransportMustAsk(_ executable: String) {
        #expect(!policy.allowsSilentWrite(isFocused: true, isLocalDaemon: true,
                                          isRemoteTerminal: false, foregroundExecutable: executable))
    }

    @Test func processLookupFailureMustAsk() {
        #expect(!policy.allowsSilentWrite(isFocused: true, isLocalDaemon: true,
                                          isRemoteTerminal: false, foregroundExecutable: nil))
    }

}
