import Testing
@testable import CmuxWindowing

@Suite("DefaultTerminalRegistrationStatus")
struct DefaultTerminalRegistrationStatusTests {
    @Test("isDefault is true only when every target matches")
    func isDefaultWhenAllMatch() {
        #expect(DefaultTerminalRegistrationStatus(matchedTargetCount: 3, targetCount: 3).isDefault)
        #expect(!DefaultTerminalRegistrationStatus(matchedTargetCount: 2, targetCount: 3).isDefault)
        #expect(!DefaultTerminalRegistrationStatus(matchedTargetCount: 0, targetCount: 3).isDefault)
    }

    @Test("zero-target status is trivially default")
    func zeroTargetIsDefault() {
        #expect(DefaultTerminalRegistrationStatus(matchedTargetCount: 0, targetCount: 0).isDefault)
    }
}
