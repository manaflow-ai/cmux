@testable import CmuxMobileShell
import Foundation
import Network
import Testing

/// Connect failures reach the host row and the terminal as sentences, never
/// as raw codes like `POSIXErrorCode(rawValue: 61): Connection refused`.
@MainActor
@Suite struct MobileSSHErrorCopyTests {
    @Test func networkFailuresReadAsSentences() {
        #expect(MobileSSHComputers.describe(NWError.posix(.ECONNREFUSED)) == L10nSSH.connectionRefused)
        #expect(MobileSSHComputers.describe(NWError.posix(.ETIMEDOUT)) == L10nSSH.connectTimedOut)
        #expect(MobileSSHComputers.describe(NWError.posix(.EHOSTUNREACH)) == L10nSSH.unreachable)
        #expect(MobileSSHComputers.describe(NWError.dns(-65554)) == L10nSSH.hostNotFound)
        #expect(MobileSSHComputers.describe(POSIXError(.ECONNREFUSED)) == L10nSSH.connectionRefused)
    }

    @Test func noNetworkMessageLeaksARawCode() {
        for code in [POSIXErrorCode.ECONNREFUSED, .ETIMEDOUT, .ENETUNREACH, .ECONNRESET] {
            let text = MobileSSHComputers.describe(NWError.posix(code))
            #expect(!text.contains("POSIXErrorCode"))
            #expect(!text.contains("rawValue"))
        }
    }
}
