import CmuxNextActions
import CmuxNextEnergy
import CmuxNextWakeups
import Testing

/// Energy Saver's session actions (p14-energy-025): "Turn Off Energy Saver for Now" and "Turn On Energy
/// Saver Again" change the policy in the input's turn, start no work, and are offered only when they
/// can do something.
@MainActor
@Suite struct EnergyActionsTests {
    static let turnOff: ActionID = "energy.saver.turnOffForNow"
    static let turnOn: ActionID = "energy.saver.turnOnNow"
    static let plugged = EnergyInputs(onBattery: false, hasBattery: true, batteryPercent: 90)
    static let lowBattery = EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 10)

    private func harness(setting: EnergySaverMode, inputs: EnergyInputs, isEnabled: Bool = true)
        -> (ActionRegistry, EnergyPolicyDriver) {
        let driver = EnergyPolicyDriver(source: EnergyPolicySource(), isEnabled: isEnabled)
        driver.update(setting: setting)
        driver.update(inputs: inputs)
        let registry = ActionRegistry.standard()
        driver.bindActions(into: registry)
        return (registry, driver)
    }

    @Test(arguments: ["energy.saver.turnOffForNow", "energy.saver.turnOnNow"])
    func bothArePaletteActionsWithNoShortcutAndNoMCPTool(id: String) throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: ActionID(rawValue: id)))
        #expect(descriptor.defaultShortcut == nil)
        #expect(descriptor.defaultChord == nil)
        #expect(descriptor.surfacePlan.palette == .offered)
        #expect(descriptor.surfacePlan.cli == .offered)
        #expect(descriptor.surfacePlan.mcp == .exempt(.systemChange), "when the saver runs is the person's call")
        #expect(descriptor.surfacePlan.contextMenu == .exempt(.noObject))
        #expect(!descriptor.title.isEmpty)
    }

    @Test func turnOffForNowTurnsTheSaverOffInTheTurnAndStartsNoWork() {
        let (registry, driver) = harness(setting: .always, inputs: Self.plugged)
        #expect(driver.source.policy.isSaver)
        #expect(registry.canPerform(Self.turnOff))
        #expect(!registry.canPerform(Self.turnOn), "nothing to undo yet")

        let work = registry.capturingWork { #expect(registry.perform(Self.turnOff)) }
        #expect(work.isEmpty, ".done starts no remote work")
        #expect(!driver.source.policy.isSaver)
        #expect(driver.isOffForSession)
        #expect(!registry.canPerform(Self.turnOff), "the saver is already off")
        #expect(registry.canPerform(Self.turnOn))
    }

    @Test func turnOnNowEndsTheSessionHoldAndTheSettingDecidesAgain() {
        let (registry, driver) = harness(setting: .auto, inputs: Self.lowBattery)
        #expect(driver.source.policy == EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(registry.perform(Self.turnOff))
        #expect(driver.source.policy == EnergyPolicy(onBattery: true))

        let work = registry.capturingWork { #expect(registry.perform(Self.turnOn)) }
        #expect(work.isEmpty)
        #expect(!driver.isOffForSession)
        #expect(driver.source.policy == EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(!registry.canPerform(Self.turnOn))
    }

    @Test func turnOffForNowIsNotOfferedWhileTheSaverIsOff() {
        let (registry, driver) = harness(setting: .auto, inputs: Self.plugged)
        #expect(!driver.source.policy.isSaver)
        #expect(!registry.canPerform(Self.turnOff))
        #expect(!registry.perform(Self.turnOff))
        #expect(!driver.isOffForSession)
    }

    @Test func neitherIsOfferedWithTheFeatureOff() {
        let (registry, driver) = harness(setting: .always, inputs: Self.lowBattery, isEnabled: false)
        #expect(!driver.source.policy.isSaver)
        #expect(!registry.canPerform(Self.turnOff))
        #expect(!registry.canPerform(Self.turnOn))
    }

    /// Chrome's rule: plugging the Mac in ends "Turn Off for Now", so "Turn On Again" has nothing to do.
    @Test func pluggingInEndsTheHold() {
        let (registry, driver) = harness(setting: .onBattery, inputs: Self.lowBattery)
        #expect(registry.perform(Self.turnOff))
        driver.update(inputs: Self.plugged)
        #expect(!driver.isOffForSession)
        #expect(!registry.canPerform(Self.turnOn))
    }

    /// The standard catalog has both, and the driver binds both (the App calls `bindActions` once), so
    /// every entrypoint (palette, CLI, socket) reaches the same handler.
    @Test func theDriverBindsBothCatalogActions() {
        let registry = ActionRegistry.standard()
        #expect(registry.unboundActionIDs().contains(Self.turnOff))
        #expect(registry.unboundActionIDs().contains(Self.turnOn))
        let driver = EnergyPolicyDriver(source: EnergyPolicySource(), isEnabled: true)
        driver.bindActions(into: registry)
        #expect(!registry.unboundActionIDs().contains(Self.turnOff))
        #expect(!registry.unboundActionIDs().contains(Self.turnOn))
    }
}
