import CmuxTerminalCore
import Foundation
import Testing

@Suite struct TerminalSurfaceCommandExitPolicyTests {
    @Test func waitAfterCommandHoldsTheSurfaceOpen() {
        let applied = TerminalSurfaceCommandExitPolicy.waitAfterCommand
            .applying(to: CmuxSurfaceConfigTemplate())

        #expect(applied.waitAfterCommand)
    }

    @Test func waitAfterCommandAppliesWithoutInheritedConfiguration() {
        let applied = TerminalSurfaceCommandExitPolicy.waitAfterCommand.applying(to: nil)

        #expect(applied.waitAfterCommand)
    }

    @Test func closeOnExitClearsAnInheritedWait() {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.waitAfterCommand = true

        let applied = TerminalSurfaceCommandExitPolicy.closeOnExit.applying(to: inherited)

        #expect(!applied.waitAfterCommand)
    }

    @Test func policyPreservesUnrelatedConfiguration() {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.setFontSize(13, isExplicitOverride: true)
        inherited.workingDirectory = "/tmp/inherited"
        inherited.command = "echo inherited"
        inherited.environmentVariables = ["CMUX_TEST": "inherited"]
        inherited.initialInput = "pwd\n"

        let applied = TerminalSurfaceCommandExitPolicy.closeOnExit.applying(to: inherited)

        #expect(applied.fontSizeLineage == inherited.fontSizeLineage)
        #expect(applied.workingDirectory == inherited.workingDirectory)
        #expect(applied.command == inherited.command)
        #expect(applied.environmentVariables == inherited.environmentVariables)
        #expect(applied.initialInput == inherited.initialInput)
    }
}
