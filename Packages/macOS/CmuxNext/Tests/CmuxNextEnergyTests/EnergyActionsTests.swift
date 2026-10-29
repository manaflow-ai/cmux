import CmuxNextActions
import CmuxNextEnergy
import CmuxNextPalette
import CmuxNextWakeups
import Testing

/// Energy Saver's session actions: "Turn Off Energy Saver for Now" and "Turn On Energy
/// Saver Again" change the policy in the input's turn, start no work, are offered only when they can do
/// something, and say why not otherwise.
@MainActor
@Suite struct EnergyActionsTests {
    static let turnOff = EnergySaverAction.turnOffForNow.id
    static let turnOn = EnergySaverAction.turnOnNow.id
    static let plugged = EnergyInputs(onBattery: false, hasBattery: true, batteryPercent: 90)
    static let lowBattery = EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 10)
    static let pluggedInLowPowerMode = EnergyInputs(lowPowerMode: true, onBattery: false, hasBattery: true, batteryPercent: 90)

    private func harness(setting: EnergySaverMode, inputs: EnergyInputs, isEnabled: Bool = true)
        -> (ActionRegistry, EnergyPolicyDriver) {
        let driver = EnergyPolicyDriver(source: EnergyPolicySource(), isEnabled: isEnabled)
        driver.update(setting: setting)
        driver.update(inputs: inputs)
        let registry = ActionRegistry.standard()
        driver.bindActions(into: registry)
        return (registry, driver)
    }

    /// The palette rows as the App lists them: `AppServices.paletteBuilt` hides the driver's
    /// `paletteHiddenActionIDs`.
    private func paletteRows(_ registry: ActionRegistry, _ driver: EnergyPolicyDriver) -> Set<ActionID> {
        let provider = RegistryPaletteProvider(registry: registry, includeUnbound: false)
        provider.hiddenIDs.formUnion(driver.paletteHiddenActionIDs)
        return Set(provider.makeItems().compactMap(\.actionID)).intersection([Self.turnOff, Self.turnOn])
    }

    @Test(arguments: EnergySaverAction.allCases)
    func bothArePaletteActionsUnderTheEnergyCLIGroupAndMCP(action: EnergySaverAction) throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: action.id))
        #expect(descriptor.defaultShortcut == nil)
        #expect(descriptor.defaultChord == nil)
        #expect(descriptor.surfacePlan.palette == .offered)
        #expect(descriptor.surfacePlan.cli == .offered)
        #expect(descriptor.surfacePlan.mcp == .offered, "CLI/MCP parity (p14-energy.md, D)")
        #expect(descriptor.surfacePlan.contextMenu == .exempt(.noObject))
        #expect(descriptor.cliName.hasPrefix("energy "), "one `cmux energy` namespace with p14-energy-033")
        #expect(!descriptor.title.isEmpty)
    }

    @Test func theCLINamesAreTheEnergyGroupVerbs() throws {
        let registry = ActionRegistry.standard()
        #expect(try #require(registry.descriptor(for: Self.turnOff)).cliName == "energy turn-off-for-now")
        #expect(try #require(registry.descriptor(for: Self.turnOn)).cliName == "energy turn-on")
    }

    @Test func turnOffForNowTurnsTheSaverOffInTheTurnAndStartsNoWork() {
        let (registry, driver) = harness(setting: .always, inputs: Self.plugged)
        #expect(driver.source.policy.isSaver)
        #expect(registry.canPerform(Self.turnOff))
        #expect(!registry.canPerform(Self.turnOn), "nothing to undo yet")
        #expect(registry.unavailableReason(for: Self.turnOn) == EnergySaverActionRefusal.notTurnedOff.reason)
        #expect(paletteRows(registry, driver) == [Self.turnOff])

        let work = registry.capturingWork { #expect(registry.perform(Self.turnOff)) }
        #expect(work.isEmpty, ".done starts no remote work")
        #expect(!driver.source.policy.isSaver)
        #expect(driver.isOffForSession)
        #expect(!registry.canPerform(Self.turnOff), "the saver is already off")
        #expect(registry.unavailableReason(for: Self.turnOff) == EnergySaverActionRefusal.saverIsOff.reason)
        #expect(registry.canPerform(Self.turnOn))
        #expect(paletteRows(registry, driver) == [Self.turnOn])
    }

    @Test func turnOnNowEndsTheSessionHoldAndTheSettingDecidesAgain() {
        let (registry, driver) = harness(setting: .auto, inputs: Self.lowBattery)
        #expect(driver.source.policy == EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(registry.perform(Self.turnOff))
        #expect(driver.source.policy == EnergyPolicy(onBattery: true, offForNow: true))

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
        #expect(registry.unavailableReason(for: Self.turnOff) == EnergySaverActionRefusal.saverIsOff.reason)
        #expect(!registry.perform(Self.turnOff))
        #expect(!driver.isOffForSession)
        #expect(paletteRows(registry, driver).isEmpty)
    }

    /// With the feature off neither row is in the palette, and `action.run` says the feature is off.
    @Test func neitherIsOfferedOrListedWithTheFeatureOff() {
        let (registry, driver) = harness(setting: .always, inputs: Self.lowBattery, isEnabled: false)
        #expect(!driver.source.policy.isSaver)
        for id in [Self.turnOff, Self.turnOn] {
            #expect(!registry.canPerform(id))
            #expect(registry.unavailableReason(for: id) == EnergySaverActionRefusal.featureOff.reason)
        }
        #expect(driver.paletteHiddenActionIDs == [Self.turnOff, Self.turnOn])
        #expect(paletteRows(registry, driver).isEmpty)
    }

    /// The hold stays when Low Power Mode ends on AC (no battery -> AC edge), but ending it would leave
    /// the saver off, so "Turn On Again" is not offered: it would promise a change it cannot make.
    @Test func turnOnAgainIsNotOfferedWhenEndingTheHoldLeavesTheSaverOff() {
        let (registry, driver) = harness(setting: .auto, inputs: Self.pluggedInLowPowerMode)
        #expect(driver.source.policy.isSaver)
        #expect(registry.perform(Self.turnOff))
        driver.update(inputs: Self.plugged)
        #expect(driver.isOffForSession, "no battery -> AC edge: the hold stays")
        #expect(!registry.canPerform(Self.turnOn))
        #expect(registry.unavailableReason(for: Self.turnOn) == EnergySaverActionRefusal.wouldStayOff.reason)
        #expect(paletteRows(registry, driver).isEmpty)
        // Low Power Mode on again: ending the hold would turn the saver on, so the row is back.
        driver.update(inputs: Self.pluggedInLowPowerMode)
        #expect(registry.canPerform(Self.turnOn))
        #expect(paletteRows(registry, driver) == [Self.turnOn])
    }

    /// Chrome's rule: plugging the Mac in ends "Turn Off for Now", so "Turn On Again" has nothing to do.
    @Test func pluggingInEndsTheHold() {
        let (registry, driver) = harness(setting: .onBattery, inputs: Self.lowBattery)
        #expect(registry.perform(Self.turnOff))
        driver.update(inputs: Self.plugged)
        #expect(!driver.isOffForSession)
        #expect(!registry.canPerform(Self.turnOn))
        #expect(registry.unavailableReason(for: Self.turnOn) == EnergySaverActionRefusal.notTurnedOff.reason)
    }

    @Test(arguments: [EnergySaverActionRefusal.featureOff, .saverIsOff, .notTurnedOff, .wouldStayOff])
    func everyRefusalHasAReason(refusal: EnergySaverActionRefusal) {
        #expect(!refusal.reason.isEmpty)
    }

    /// The standard catalog has both, and the driver binds both (the App calls `bindActions` once), so
    /// every entrypoint (palette, CLI, socket, MCP) reaches the same handler.
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
