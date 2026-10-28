import AppKit
import CmuxNextActions
import Testing

/// One toggle, every surface: the palette, the main menu and menu bar (``ActionRegistry/makeMenuItem(for:)``
/// retitled as the menu opens) and right-click rows all read the title for the target's state from
/// ``ActionRegistry/displayTitle(for:invocation:)`` (Lawrence 2026-10-27, "Pin/Unpin Workspace").
@MainActor
struct ActionToggleTitlesTests {
    final class State { var on: Set<String> = [] }

    static let id: ActionID = "test.togglePin"

    static func registry(_ state: State) -> ActionRegistry {
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: ActionBudgetMonitor()))
        registry.seed([
            ActionDescriptor(id: id, title: "Pin Thing", keywords: ["pin"], category: .workspace, symbol: "pin",
                             surfaces: [.palette, .menu, .contextMenu], targets: [.workspace])
                .toggling(whenOn: "Unpin Thing", symbolWhenOff: "pin", symbolWhenOn: "pin.slash"),
        ])
        registry.bind(id) {}
        // Nil target: the focused object ("focused").
        ActionTargetTitles.setState(id, in: registry) { invocation in state.on.contains(invocation.target?.id ?? "focused") }
        return registry
    }

    @Test func theCatalogTitleIsTheOffTitleAndBothAreKeywords() throws {
        let descriptor = try #require(Self.registry(State()).descriptor(for: Self.id))
        #expect(descriptor.title == "Pin Thing")
        #expect(descriptor.toggleTitles?.whenOn == "Unpin Thing")
        #expect(descriptor.keywords.contains("Pin Thing") && descriptor.keywords.contains("Unpin Thing"))
    }

    @Test func theTitleAndSymbolFollowTheTargetsState() {
        let state = State()
        let registry = Self.registry(state)
        #expect(registry.displayTitle(for: Self.id) == "Pin Thing")
        #expect(registry.displaySymbol(for: Self.id) == "pin")
        state.on = ["focused"]
        #expect(registry.displayTitle(for: Self.id) == "Unpin Thing")
        #expect(registry.displaySymbol(for: Self.id) == "pin.slash")
        let other = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: "other"))
        #expect(registry.displayTitle(for: Self.id, invocation: other) == "Pin Thing")
    }

    @Test func aMainMenuOrMenuBarRowIsRetitledWhenTheMenuOpens() throws {
        _ = NSApplication.shared
        let state = State()
        let registry = Self.registry(state)
        let item = try #require(registry.makeMenuItem(for: Self.id))
        let validator = try #require(item.target as? NSMenuItemValidation)
        _ = validator.validateMenuItem(item)
        #expect(item.title == "Pin Thing")
        state.on = ["focused"]
        _ = validator.validateMenuItem(item)
        #expect(item.title == "Unpin Thing")
    }

    @Test func aRightClickRowNamesTheChangeWithoutACheckMark() throws {
        _ = NSApplication.shared
        let state = State()
        state.on = ["clicked"]
        let registry = Self.registry(state)
        let item = try #require(registry.makeConfiguredContextItem(
            for: Self.id, target: ActionTargetRef(kind: .workspace, id: "clicked"), title: nil))
        #expect(item.title == "Unpin Thing")
        #expect(item.state == .off, "the title says it; no check mark as well")
    }

    @Test func aStateReadThatRefusesShowsNoNotice() {
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: ActionBudgetMonitor()))
        var notices: [String] = []
        registry.refusalObserver = { reason, _ in notices.append(reason) }
        registry.seed([ActionDescriptor(id: Self.id, title: "Pin Thing", category: .workspace).toggling(whenOn: "Unpin Thing")])
        registry.bind(Self.id) {}
        ActionTargetTitles.setState(Self.id, in: registry) { [weak registry] _ in
            registry?.refuse("no workspace")
            return nil
        }
        #expect(registry.displayTitle(for: Self.id) == "Pin Thing")
        #expect(notices.isEmpty)
    }
}
