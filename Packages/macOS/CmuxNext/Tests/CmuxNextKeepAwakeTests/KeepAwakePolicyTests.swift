@testable import CmuxNextKeepAwake
import CmuxNextSettings
import Foundation
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

    /// The setting the menu bar's Keeping Mac awake line opens is the one behind the hold: agents
    /// and commands before phones, and none for the Keep Mac Awake action alone.
    @Test func theHoldNamesItsSetting() {
        #expect(KeepAwakePolicy().setting == nil)
        #expect(KeepAwakePolicy(manual: true).setting == nil)
        #expect(KeepAwakePolicy(agentsWorking: true).setting == "sessions.keepAwake")
        #expect(KeepAwakePolicy(commandsRunning: 1, commands: true).setting == "sessions.keepAwake")
        #expect(KeepAwakePolicy(iPhoneServing: true, phone: .pluggedIn).setting == "phone.keepAwake")
        #expect(KeepAwakePolicy(manual: true, agentsWorking: true, iPhoneServing: true, phone: .pluggedIn).setting == "sessions.keepAwake")
        // An agent the choice does not allow (on battery) leaves the phones' setting.
        #expect(KeepAwakePolicy(agentsWorking: true, iPhoneServing: true, phone: .always, onBattery: true).setting == "phone.keepAwake")
    }

    /// A long terminal command holds only with `sessions.keepAwakeForCommands` on, and then as
    /// `sessions.keepAwake` allows: Off there turns it off too.
    @Test func longCommandsHoldOnlyWhenTheirSettingIsOn() {
        #expect(!KeepAwakePolicy(commandsRunning: 2).holds)
        #expect(KeepAwakePolicy(commandsRunning: 2, commands: true).holds)
        #expect(!KeepAwakePolicy(commandsRunning: 0, commands: true).holds)
        #expect(!KeepAwakePolicy(commandsRunning: 1, commands: true, onBattery: true).holds)
        #expect(KeepAwakePolicy(agents: .always, commandsRunning: 1, commands: true, onBattery: true).holds)
        #expect(!KeepAwakePolicy(agents: .off, commandsRunning: 1, commands: true).holds)
    }

    /// The Rust rule through the app FFI: a printing command past a minute counts, an agent's
    /// terminal and a young command do not, and the young one names the next look.
    @Test func theRustRuleCountsLongPrintingCommands() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = KeepAwakeCommands.ms(now)
        let commands = KeepAwakeCommands(commands: [
            .init(sinceMs: ms - 300_000, outputMs: ms - 1_000, agent: false, terminal: true),
            .init(sinceMs: ms - 300_000, outputMs: ms, agent: true, terminal: true),
            .init(sinceMs: ms - 20_000, outputMs: nil, agent: false, terminal: true),
        ])
        #expect(commands.plan(now: now) == .init(running: 1, quiet: [], recheckMs: 40_000))
        #expect(KeepAwakeCommands().plan(now: now) == .init())
    }
}
