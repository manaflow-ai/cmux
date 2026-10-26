import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextSettings
import Testing

/// `memory.saver.<mode>` (p07-memory-065): each action applies the mode in its own turn, returns
/// `.done` well inside the 10 ms action budget, and starts the cmux-next.json write (the default as no
/// key); a managed key refuses before anything changes. Each mode is a Settings palette action the CLI
/// offers; MCP sets it through `settings_set`, as `browser.hibernation`.
@MainActor @Suite struct MemorySaverSettingActionTests {
    @MainActor final class Rig {
        let registry = ActionRegistry.standard()
        var refusal: String?
        private(set) var writes: [([String], JSONValue?)] = []
        private(set) var applied: [MemorySaverMode] = []

        init() {
            MemorySaverSetting.bindActions(into: registry, save: { [unowned self] path, value in
                if let refusal = self.refusal { return refusal }
                self.writes.append((path, value))
                return nil
            }, apply: { [unowned self] mode in self.applied.append(mode) })
        }
    }

    @Test(arguments: MemorySaverMode.allCases)
    func eachActionAppliesTheModeInItsTurnAndWritesTheSetting(mode: MemorySaverMode) throws {
        let rig = Rig()
        let clock = ContinuousClock()
        let started = clock.now
        #expect(rig.registry.perform(mode.actionID, invocation: ActionInvocation(origin: .user)))
        let took = clock.now - started
        #expect(rig.applied == [mode], "the mode was not applied in the action's turn")
        #expect(took < .milliseconds(10), "\(mode.actionID.rawValue) took \(took), past the 10 ms action budget")
        let write = try #require(rig.writes.last)
        #expect(write.0 == ["memory", "saver"])
        let expected: JSONValue? = mode == .medium ? nil : .string(mode.rawValue)
        #expect(write.1 == expected, "the default is written as no key")
    }

    @Test func aManagedKeyRefusesAndChangesNothing() {
        let rig = Rig()
        rig.refusal = "memory.saver is managed"
        _ = rig.registry.perform(MemorySaverMode.off.actionID, invocation: ActionInvocation(origin: .user))
        #expect(rig.applied.isEmpty, "a managed key changed the live mode")
        #expect(rig.writes.isEmpty)
    }

    @Test(arguments: MemorySaverMode.allCases)
    func everyModeIsASettingsPaletteActionTheCLIOffers(mode: MemorySaverMode) throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: mode.actionID))
        #expect(mode.actionID.rawValue == "memory.saver.\(mode.rawValue)")
        #expect(descriptor.defaultShortcut == nil)
        #expect(descriptor.category == .settings)
        #expect(descriptor.surfacePlan.palette == .offered)
        #expect(descriptor.surfacePlan.cli == .offered)
        #expect(descriptor.surfacePlan.mcp == .exempt(.systemChange), "MCP sets it through settings_set, as browser.hibernation")
        #expect(descriptor.surfacePlan.contextMenu == .exempt(.noObject))
        #expect(descriptor.cliName.hasPrefix("settings "))
        #expect(descriptor.cliName.hasSuffix("memory-saver"))
    }

    @Test func theDiscardTogglesAreOffAndNameEveryKind() {
        let kinds = ["internalPages", "topPages", "conversations", "parkedWorkspaces", "pageTabs", "remoteTabs", "terminalGPURelease"]
        #expect(MemoryDiscardToggles.toggles.map(\.key) == kinds.map { "memory.discard.\($0)" })
        #expect(MemoryDiscardToggles.toggles.allSatisfy { $0.defaultValue == false }, "a discard toggle is on by default")
        #expect(MemoryDiscardToggles.all.count == kinds.count)
    }
}
