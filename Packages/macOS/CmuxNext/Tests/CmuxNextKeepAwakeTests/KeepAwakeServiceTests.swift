@testable import CmuxNextKeepAwake
import Testing

/// The service takes the power source the App pushes from its energy monitor (`setOnBattery`) and
/// keeps no power-source monitor of its own.
@MainActor
struct KeepAwakeServiceTests {
    @Test func goingOnBatteryDropsThePhoneHoldAndAdapterPowerTakesItBack() {
        let service = KeepAwakeService()
        service.setPhoneServing(true)
        #expect(service.isHolding, "phone access (plugged in, the default) does not hold on adapter power")
        service.setOnBattery(true)
        #expect(!service.policy.holds && !service.isHolding, "the hold stays on battery")
        service.setOnBattery(false)
        #expect(service.isHolding)
        service.setPhoneServing(false)
        #expect(!service.isHolding)
    }

    @Test func theActionHoldsOnBatteryToo() {
        let service = KeepAwakeService()
        service.setOnBattery(true)
        service.toggleManual()
        #expect(service.isHolding)
        service.toggleManual()
        #expect(!service.isHolding)
    }
}
