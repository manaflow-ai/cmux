import Foundation
import Testing
@testable import CmuxComputerUse

@MainActor
struct ComputerUseOnboardingRecoveryTests {
    @Test("An interrupted presentation returns to actionable setup")
    func interruptedPresentationIsRecoverable() throws {
        let suite = "ComputerUseOnboardingRecoveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ComputerUseOnboardingStore(defaults: defaults, scope: "test")
        store.apply(.setEnabled(true))
        store.apply(.onboardingPresented)
        #expect(store.phase == .onboarding)

        store.recoverInterruptedOnboarding()

        #expect(store.phase == .onboardingRequired)
        #expect(!store.completionCommitted)
    }

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
