import Foundation
import Testing
@testable import CmuxMobileShell

@Suite
struct MobileSSHConnectionAttemptRegistryTests {
    @Test func lateCompletionCannotClearReplacementAttempt() {
        let hostID = UUID()
        var registry = MobileSSHConnectionAttemptRegistry()
        let firstGeneration = registry.begin(for: hostID)
        registry.invalidate(for: hostID)
        let replacementGeneration = registry.begin(for: hostID)

        let staleClear = registry.clearIfCurrent(firstGeneration, for: hostID)
        #expect(!staleClear)
        #expect(registry.isCurrent(replacementGeneration, for: hostID))
    }
}
