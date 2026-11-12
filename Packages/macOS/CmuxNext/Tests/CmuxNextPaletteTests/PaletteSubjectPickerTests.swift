import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Leo, 2026-11-12: “what” — Open Desktop must collect a machine instead of
/// running with no target and showing the control socket's CLI instructions.
@MainActor
struct PaletteSubjectPickerTests {
    private final class Targets: PaletteTargetSource {
        var reads = 0
        var options = [PaletteTargetOption(id: "chosen", title: "Design desktop")]
        func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
            reads += 1
            return options
        }
    }

    private func row(_ id: ActionID, registry: ActionRegistry, targets: Targets,
                     captured: [ActionTargetRef] = []) throws -> PaletteItem {
        let provider = RegistryPaletteProvider(registry: registry)
        provider.targets = targets
        provider.capturedTargets = captured
        return try #require(provider.makeItems().first { $0.actionID == id })
    }

    @Test func missingMachineOpensPickerAndSelectionSuppliesTheSubject() async throws {
        let registry = ActionRegistry.standard(), targets = Targets()
        var received: ActionInvocation?
        registry.bind("cloudOpenDesktop", invoke: { received = $0 })
        let item = try row("cloudOpenDesktop", registry: registry, targets: targets)
        #expect(targets.reads == 0, "listing commands must not enumerate machines")
        guard case .push(let page) = item.primary.effect.resolved() else {
            Issue.record("Open Desktop ran instead of asking which machine"); return
        }
        #expect(received == nil)
        let choice = try #require(await page.providers.first?.items().first)
        #expect(choice.title == "Design desktop")
        guard case .perform(let run) = choice.primary.effect.resolved() else {
            Issue.record("choosing the machine did not complete the invocation"); return
        }
        run()
        #expect(received?.target == ActionTargetRef(kind: .machine, id: "chosen"))
        #expect(received?.arguments.isEmpty == true, "the subject is not a CLI argument")
    }

    @Test func capturedMachineStaysPinnedWhenTheActionHasNoArguments() throws {
        let registry = ActionRegistry.standard(), targets = Targets()
        var received: ActionTargetRef?
        registry.bind("cloudOpenDesktop", invoke: { received = $0.target })
        let machine = ActionTargetRef(kind: .machine, id: "original")
        let item = try row("cloudOpenDesktop", registry: registry, targets: targets, captured: [machine])
        guard case .perform(let run) = item.primary.effect.resolved() else {
            Issue.record("a captured target must not ask again"); return
        }
        run()
        #expect(received == machine)
        #expect(targets.reads == 0)
    }

    @Test func sharedMachinePickerPrecedesRequiredFilePath() async throws {
        let registry = ActionRegistry.standard(), targets = Targets()
        registry.bind("cloudFileRead", invoke: { _ in })
        let item = try row("cloudFileRead", registry: registry, targets: targets)
        guard case .push(let page) = item.primary.effect.resolved() else {
            Issue.record("file action must choose its machine before asking for a path"); return
        }
        let choice = try #require(await page.providers.first?.items().first)
        guard case .textInput = choice.primary.effect.resolved() else {
            Issue.record("the file path must follow the shared machine picker"); return
        }
    }

    @Test func inlineRepairRunsCreationWithoutTargetingTheOldMachine() async throws {
        let registry = ActionRegistry.standard(), targets = Targets()
        var created = false, opened = false
        registry.bind("cloudOpenDesktop", invoke: { _ in opened = true })
        registry.bind("newCloudMachine", invoke: {
            #expect($0.target == nil)
            created = true
        })
        targets.options = [PaletteTargetOption(id: "old", title: "Older machine", subtitle: "This image has no desktop",
            recovery: PaletteTargetRecovery(action: "newCloudMachine", title: "Create desktop machine"))]
        let item = try row("cloudOpenDesktop", registry: registry, targets: targets)
        guard case .push(let page) = item.primary.effect.resolved() else { Issue.record("missing picker"); return }
        let choice = try #require(await page.providers.first?.items().first)
        #expect(choice.accessory == "Create desktop machine")
        guard case .perform(let run) = choice.primary.effect.resolved() else { Issue.record("missing repair"); return }
        run()
        #expect(created)
        #expect(!opened)
    }

    @Test func missingTargetSourceNeverAsksForAControlSocketID() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "cloudOpenDesktop" })
        let flow = PaletteArgumentFlow(registry: .standard(), descriptor: descriptor, targets: nil)
        guard case .push = flow.effect(collected: ActionInvocation()) else {
            Issue.record("a missing target source must never become a CLI text input"); return
        }
    }

    @Test func targetContextDoesNotBypassGlobalAvailability() throws {
        let registry = ActionRegistry.standard(), targets = Targets()
        registry.bind("cloudOpenDesktop", unavailable: { "Account is unavailable" }, invoke: { _ in })
        let item = try row("cloudOpenDesktop", registry: registry, targets: targets)
        #expect(!item.isEnabled)
        #expect(item.subtitle == "Account is unavailable")
    }

    @Test func creationWithNoSubjectKeepsItsExistingMeaning() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "newCloudWorkspace" })
        let targets = Targets()
        let flow = PaletteArgumentFlow(registry: .standard(), descriptor: descriptor, targets: targets)
        guard case .perform = flow.effect(collected: ActionInvocation()) else {
            Issue.record("creating a machine must not ask for an existing machine"); return
        }
        #expect(targets.reads == 0)
    }
}
