@testable import CmuxNextKeepAwake
import CmuxNextSettings
import Testing

/// Who keeps this Mac awake: the Keep Mac Awake action always; a working agent
/// only as `sessions.keepAwake` allows on the current power source.
struct KeepAwakePolicyTests {
    @Test func nothingAsksNothingHolds() {
        #expect(!KeepAwakePolicy().holds)
    }

    @Test func aWorkingAgentHoldsOnAdapterPowerByDefault() {
        #expect(KeepAwakePolicy(agentsWorking: true).holds)
        #expect(!KeepAwakePolicy(agentsWorking: true, onBattery: true).holds)
    }

    @Test(arguments: [
        (SessionKeepAwakeSetting.off, false, false), (.off, true, false),
        (.pluggedIn, false, true), (.pluggedIn, true, false),
        (.always, false, true), (.always, true, true),
    ])
    func theChoiceDecidesForAgents(choice: SessionKeepAwakeSetting, onBattery: Bool, holds: Bool) {
        #expect(KeepAwakePolicy(agentsWorking: true, agents: choice, onBattery: onBattery).holds == holds)
    }

    @Test func idleAgentsNeverHold() {
        for choice in SessionKeepAwakeSetting.allCases {
            #expect(!KeepAwakePolicy(agentsWorking: false, agents: choice).holds)
        }
    }

    @Test func theActionHoldsEvenWithTheSettingOffOnBattery() {
        #expect(KeepAwakePolicy(manual: true, agents: .off, onBattery: true).holds)
    }

    @Test(arguments: [
        (PhoneKeepAwakeSetting.off, false, false), (.pluggedIn, false, true), (.pluggedIn, true, false),
        (.always, true, true),
    ])
    func phoneAccessHoldsAsItsOwnChoiceAllows(choice: PhoneKeepAwakeSetting, onBattery: Bool, holds: Bool) {
        #expect(KeepAwakePolicy(phoneServing: true, phone: choice, onBattery: onBattery).holds == holds)
    }

    @Test(arguments: [false, true])
    func eitherPhoneHostHoldsIndependently(onBattery: Bool) {
        var policy = KeepAwakePolicy(phoneServing: true, iPhoneServing: true, phone: .always, onBattery: onBattery)
        #expect(policy.holds)
        policy.phoneServing = false
        #expect(policy.holds)
        policy.phoneServing = true
        policy.iPhoneServing = false
        #expect(policy.holds)
        policy.phoneServing = false
        #expect(!policy.holds)
    }

    @Test func nextPhoneRespectsPowerChoice() {
        #expect(!KeepAwakePolicy(iPhoneServing: true, phone: .off).holds)
        #expect(KeepAwakePolicy(iPhoneServing: true, phone: .pluggedIn).holds)
        #expect(!KeepAwakePolicy(iPhoneServing: true, phone: .pluggedIn, onBattery: true).holds)
    }

    @Test func phoneAccessOffNeverHolds() {
        #expect(!KeepAwakePolicy(phoneServing: false, phone: .always).holds)
    }
}
