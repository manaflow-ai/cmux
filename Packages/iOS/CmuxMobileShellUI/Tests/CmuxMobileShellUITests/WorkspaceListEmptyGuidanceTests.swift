#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

/// Which copy the aggregated (All Computers) empty state gives. An SSH-only
/// user has no Mac to pair, so the Mac-pairing copy would describe a Mac
/// they do not have; any paired Mac keeps Macs the context (PRD D29).
@Suite struct WorkspaceListEmptyGuidanceTests {
    @Test func sshComputersWithoutAPairedMacGetSSHGuidance() {
        #expect(
            WorkspaceListEmptyGuidance(hasSSHComputers: true, hasPairedMacs: false)
                == .sshComputers
        )
    }

    @Test func aPairedMacKeepsMacsTheContext() {
        #expect(
            WorkspaceListEmptyGuidance(hasSSHComputers: true, hasPairedMacs: true)
                == .macPairing
        )
    }

    @Test func withoutSSHComputersTheMacCopyStands() {
        #expect(
            WorkspaceListEmptyGuidance(hasSSHComputers: false, hasPairedMacs: false)
                == .macPairing
        )
        #expect(
            WorkspaceListEmptyGuidance(hasSSHComputers: false, hasPairedMacs: true)
                == .macPairing
        )
    }
}
#endif
