import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct CLIVMWaitPollIntervalTests {
    @Test func usesProductionCadenceWithoutOverride() {
        #expect(CLIVMWaitPollInterval.resolve(environment: [:]) == 3)
    }

    @Test(arguments: ["0.01", "0.05", "3"])
    func honorsShortOverride(_ raw: String) throws {
        let expected = try #require(TimeInterval(raw))
        #expect(CLIVMWaitPollInterval.resolve(environment: ["CMUX_VM_WAIT_POLL_SECONDS": raw]) == expected)
    }

    @Test(arguments: ["3600", "3.5", "0.001", "0", "-1", "inf", "nan", "soon", ""])
    func rejectsOverrideOutsideCommandSafeRange(_ raw: String) {
        #expect(CLIVMWaitPollInterval.resolve(environment: ["CMUX_VM_WAIT_POLL_SECONDS": raw]) == 3)
    }
}
