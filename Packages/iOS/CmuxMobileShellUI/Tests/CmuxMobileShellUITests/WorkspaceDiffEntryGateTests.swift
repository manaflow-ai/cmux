import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceDiffEntryGateTests {
    @Test(arguments: [
        (true, true, true),
        (true, false, false),
        (false, true, false),
        (false, false, false),
    ])
    func requiresCapabilityAndConnection(
        supportsWorkspaceDiffs: Bool,
        isConnected: Bool,
        expected: Bool
    ) {
        let gate = WorkspaceDiffEntryGate(
            supportsWorkspaceDiffs: supportsWorkspaceDiffs,
            isConnected: isConnected
        )
        #expect(gate.canPresent == expected)
    }
}
