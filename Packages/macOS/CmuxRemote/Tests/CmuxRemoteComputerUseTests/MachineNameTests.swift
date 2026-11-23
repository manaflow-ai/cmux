// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteHost
import Darwin
import Foundation
import Testing

/// The supervisor's starting machine name is read before the host reports
/// ready. `ProcessInfo.hostName` resolved it through DNS and blocked while the
/// network had no answer (a VM with a stalled resolver: the host never became
/// ready, and Computer Use stayed unavailable).
@Suite struct MachineNameTests {
    @Test func theMachineNameNeedsNoNetwork() {
        let start = Date()
        let name = ComputerUseSupervisor.localMachineName()
        #expect(!name.isEmpty)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
