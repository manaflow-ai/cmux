#if DEBUG
import Testing
@testable import CmuxMobileTerminal

@Suite("MobileRecoveryStressConfiguration")
struct MobileRecoveryStressConfigurationTests {
    @Test("missing launch argument disables harness")
    func missingArgument() {
        #expect(MobileRecoveryStressConfiguration.parse(arguments: ["app"]) == nil)
    }

    @Test("positive launch argument sets cycle count")
    func positiveCycleCount() throws {
        let config = try #require(MobileRecoveryStressConfiguration.parse(arguments: ["app", "--cmux-recovery-stress", "17"]))
        #expect(config.cycles == 17)
    }

    @Test("missing or invalid cycle count falls back to default")
    func invalidCycleCountUsesDefault() throws {
        let missing = try #require(MobileRecoveryStressConfiguration.parse(arguments: ["app", "--cmux-recovery-stress"]))
        let invalid = try #require(MobileRecoveryStressConfiguration.parse(arguments: ["app", "--cmux-recovery-stress", "nope"]))
        let negative = try #require(MobileRecoveryStressConfiguration.parse(arguments: ["app", "--cmux-recovery-stress", "-3"]))
        #expect(missing.cycles == MobileRecoveryStressConfiguration.defaultCycles)
        #expect(invalid.cycles == MobileRecoveryStressConfiguration.defaultCycles)
        #expect(negative.cycles == MobileRecoveryStressConfiguration.defaultCycles)
    }
}
#endif
