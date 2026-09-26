@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Network
import Testing

/// Connect failures reach the host row and the terminal as sentences, never
/// as raw codes like `POSIXErrorCode(rawValue: 61): Connection refused`.
@MainActor
@Suite struct MobileSSHErrorCopyTests {
    @Test func networkFailuresReadAsSentences() {
        #expect(MobileSSHComputers.describe(NWError.posix(.ECONNREFUSED)) == L10nSSH().connectionRefused)
        #expect(MobileSSHComputers.describe(NWError.posix(.ETIMEDOUT)) == L10nSSH().connectTimedOut)
        #expect(MobileSSHComputers.describe(NWError.posix(.EHOSTUNREACH)) == L10nSSH().unreachable)
        #expect(MobileSSHComputers.describe(NWError.dns(-65554)) == L10nSSH().hostNotFound)
        #expect(MobileSSHComputers.describe(POSIXError(.ECONNREFUSED)) == L10nSSH().connectionRefused)
    }

    @Test func noNetworkMessageLeaksARawCode() {
        for code in [POSIXErrorCode.ECONNREFUSED, .ETIMEDOUT, .ENETUNREACH, .ECONNRESET] {
            let text = MobileSSHComputers.describe(NWError.posix(code))
            #expect(!text.contains("POSIXErrorCode"))
            #expect(!text.contains("rawValue"))
        }
    }

    /// A refused `pty-req` or `shell` (a server out of PTYs, a forced
    /// command) reads as a sentence, not `channelRequestRejected("pty-req")`.
    @Test func refusedChannelRequestsReadAsSentences() {
        #expect(MobileSSHComputers.describe(SSHConnectionError.channelRequestRejected("pty-req")) == L10nSSH().terminalRefused)
        #expect(MobileSSHComputers.describe(SSHConnectionError.channelRequestRejected("shell")) == L10nSSH().terminalRefused)
        let other = MobileSSHComputers.describe(SSHConnectionError.channelRequestRejected("tmux new-window: no space for new pane"))
        #expect(other == L10nSSH().requestRefused(detail: "tmux new-window: no space for new pane"))
        #expect(other.contains("no space for new pane"))
        #expect(!other.contains("channelRequestRejected"))
    }
}
