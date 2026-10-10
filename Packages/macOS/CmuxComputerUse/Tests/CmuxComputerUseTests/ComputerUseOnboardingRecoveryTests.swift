import Foundation
import Testing
@testable import CmuxComputerUse

@MainActor
struct ComputerUseOnboardingRecoveryTests {
    @Test("Ad-hoc helper identity changes when the executable changes")
    func fallbackIdentityIsContentScoped() {
        let first = ComputerUseHelperIdentity.fallbackIdentity(
            forExecutable: Data("helper-v1".utf8)
        )
        let same = ComputerUseHelperIdentity.fallbackIdentity(
            forExecutable: Data("helper-v1".utf8)
        )
        let changed = ComputerUseHelperIdentity.fallbackIdentity(
            forExecutable: Data("helper-v2".utf8)
        )

        #expect(first == same)
        #expect(first != changed)
        #expect(first.hasPrefix("content:"))
    }
}
