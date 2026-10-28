import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextSettings
import Testing

/// `memory.saver.<mode>`: each action applies the mode in its own turn, returns well
/// inside the 10 ms action budget, and the registry runs the cmux-next.json write after the turn (the
/// default as no key); a failed write puts the previous mode back. A refusal (a managed key, settings
/// not loaded) changes nothing, and while the `memorySaverSetting` feature is off no action runs. Each
/// mode is a Settings palette action the CLI offers; MCP sets it through `settings_set`, as
/// `browser.hibernation`.
@MainActor @Suite struct MemorySaverSettingActionTests {
    @MainActor final class Rig {
        let registry = ActionRegistry.standard()
        var featureOn = true
        var refusal: String?
        var failure: ActionWorkFailure?
        /// The live mode, as the App's memory coordinator holds it.
        private(set) var mode: MemorySaverMode = .medium
        private(set) var writes: [([String], JSONValue?)] = []
        private(set) var applied: [MemorySaverMode] = []

        init() {
            MemorySaverSetting.bindActions(into: registry, unavailable: { [unowned self] in
                self.featureOn ? nil : MemorySaverSetting.featureOffReason
            }, refusal: { [unowned self] _ in self.refusal }, write: { [unowned self] path, value in
                let failure = self.failure
                return { [unowned self] in
                    self.writes.append((path, value))
                    return failure
                }
            }, current: { [unowned self] in self.mode }, apply: { [unowned self] mode in
                self.mode = mode
                self.applied.append(mode)
            })
        }

        /// Performs `mode`'s action as a capturing caller (`action.run`) and waits for its write.
        func run(_ mode: MemorySaverMode) async -> Bool {
            var ran = false
            let work = registry.capturingWork { ran = registry.perform(mode.actionID, invocation: ActionInvocation(origin: .user)) }
            for task in work { _ = await task.value }
            return ran
        }
    }

    @Test(arguments: MemorySaverMode.allCases)
    func eachActionAppliesTheModeInItsTurnAndWritesTheSetting(mode: MemorySaverMode) async throws {
        let rig = Rig()
        let clock = ContinuousClock()
        var took: Duration = .zero
        let work = rig.registry.capturingWork {
            let started = clock.now
            #expect(rig.registry.perform(mode.actionID, invocation: ActionInvocation(origin: .user)))
            took = clock.now - started
        }
        #expect(rig.applied == [mode], "the mode was not applied in the action's turn")
        #expect(took < .milliseconds(10), "\(mode.actionID.rawValue) took \(took), past the 10 ms action budget")
        for task in work { _ = await task.value }
        let write = try #require(rig.writes.last)
        #expect(write.0 == ["memory", "saver"])
        let expected: JSONValue? = mode == .medium ? nil : .string(mode.rawValue)
        #expect(write.1 == expected, "the default is written as no key")
        #expect(rig.mode == mode)
    }

    /// The coordinator never keeps a mode cmux-next.json does not have: the settings follower skips a
    /// value equal to its last one, so only the effect's rollback can put the file's mode back.
    @Test func aFailedWritePutsThePreviousModeBack() async {
        let rig = Rig()
        #expect(await rig.run(.aggressive))
        #expect(rig.mode == .aggressive)

        rig.failure = "disk full"
        #expect(await rig.run(.off))
        #expect(rig.applied == [.aggressive, .off, .aggressive], "the failed write left the action's mode in place")
        #expect(rig.mode == .aggressive)
    }

    @Test func aRefusalChangesNothing() async {
        let rig = Rig()
        rig.refusal = "memory.saver is managed"
        _ = await rig.run(.off)
        #expect(rig.applied.isEmpty, "a refused write changed the live mode")
        #expect(rig.writes.isEmpty)
    }

    @Test func offTheFeatureNoActionRuns() async {
        let rig = Rig()
        rig.featureOn = false
        for mode in MemorySaverMode.allCases {
            #expect(rig.registry.unavailableReason(for: mode.actionID) == MemorySaverSetting.featureOffReason)
            #expect(await rig.run(mode) == false, "\(mode.actionID.rawValue) ran with memorySaverSetting off")
        }
        #expect(rig.applied.isEmpty, "an action changed the live mode with the feature off")
        #expect(rig.writes.isEmpty)
        #expect(!MemorySaverSetting.featureOffReason.isEmpty)
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
        let kinds = ["internalPages", "topPages", "conversations", "parkedWorkspaces", "sidebarSections", "pageTabs", "remoteTabs",
                     "terminalGPURelease"]
        #expect(MemoryDiscardToggles.toggles.map(\.key) == kinds.map { "memory.discard.\($0)" })
        #expect(MemoryDiscardToggles.toggles.allSatisfy { $0.defaultValue == false }, "a discard toggle is on by default")
        #expect(MemoryDiscardToggles.all.count == kinds.count)
    }
}
