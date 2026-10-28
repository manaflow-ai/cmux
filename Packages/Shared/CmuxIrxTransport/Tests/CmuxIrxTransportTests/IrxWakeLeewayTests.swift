import Testing
@testable import CmuxIrxTransport

struct IrxWakeLeewayTests {
    @Test func noDelayIsExact() {
        #expect(IrxWakeLeeway(delay: .zero).tolerance == .zero)
        #expect(IrxWakeLeeway(delay: .milliseconds(-5)).tolerance == .zero)
    }

    @Test func subsecondDelaysGetChromiumsDefaultLeeway() {
        #expect(IrxWakeLeeway(delay: .milliseconds(10)).tolerance == .milliseconds(8))
        #expect(IrxWakeLeeway(delay: .milliseconds(999)).tolerance == .milliseconds(8))
    }

    @Test func longerDelaysGetTenPercentCappedAtOneSecond() {
        #expect(IrxWakeLeeway(delay: .seconds(1)).tolerance == .milliseconds(100))
        #expect(IrxWakeLeeway(delay: .seconds(5)).tolerance == .milliseconds(500))
        #expect(IrxWakeLeeway(delay: .seconds(90)).tolerance == .seconds(1))
        #expect(IrxWakeLeeway(delay: .seconds(3600)).tolerance == .seconds(1))
    }

    @Test func secondsSeamClampsWhatDurationCanNotHold() {
        #expect(IrxWakeLeeway(seconds: .nan).delay == .zero)
        #expect(IrxWakeLeeway(seconds: -3).delay == .zero)
        #expect(IrxWakeLeeway(seconds: .infinity).delay == .seconds(2_147_483_648))
        #expect(IrxWakeLeeway(seconds: 300).delay == .seconds(300))
        #expect(IrxWakeLeeway(seconds: 300).tolerance == .seconds(1))
    }
}
