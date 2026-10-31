@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import AppKit
import CmuxNextActions
import Observation
import Testing

/// Every Cmd-T built the New Tab dropdown's copy of the Commands palette again, availability included, on the
/// frame after the page showed (`NewTabPage.fillPaletteActions` -> `PaletteController.commandEntries` ->
/// `RegistryPaletteProvider.makeItems`). A cache of that list cannot hit: a Cmd-T changes the state the rows'
/// availability reads, and the head of the first fix built it on 88 of 88 presses (fleet job
/// 47430048563a3342afc8e209, span `newTab.paletteActions`). So the page's list is a catalog that decides no
/// availability at all, and a query's shown rows ask for their state (`newTab.actionStates`).
@MainActor
struct NewTabPaletteCatalogTests {
    /// The web New Tab page's action list, as the page gets it (`NewTabPage.omnibar`).
    private static func pageActions(_ services: AppServices) -> [AgentPaneOmnibar.Action] {
        NewTabPage.omnibar(services, excluding: nil).actions
    }

    private static func services() -> (AppServices, ActionRegistry) {
        _ = NSApplication.shared // the palette's context reads NSApp's key window
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = services.registry
        registry.context = ActionContext(rawValue: .max)
        services.keyWindowSource = { nil }
        let ids = registry.descriptors.filter { $0.isPaletteVisible && !$0.isDebugOnly && $0.arguments.isEmpty }.map(\.id)
        for id in ids where !registry.isBound(id) { registry.bind(id) {} }
        return (services, registry)
    }

    /// What a real Cmd-T changes between two presses: the focus facts, a window, and app state that a row's
    /// availability reads (here an observable gate, as the store's tabs are for Close Tab). Neither New Tab list
    /// may decide any row's availability: on the base every list ran every row's availability closure.
    @Test func twoNewTabsWithACmdTsStateChangeBetweenDecideNoAvailability() {
        let (services, registry) = Self.services()
        let gate = PaletteCatalogGate()
        var decided = 0
        registry.bind("newWindow", isEnabled: {
            decided += 1
            return gate.open
        }) {}
        let first = Self.pageActions(services)
        registry.context = ActionContext(rawValue: .max).subtracting(ActionContext(rawValue: 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.orderFront(nil)
        gate.open = false
        let second = Self.pageActions(services)
        window.orderOut(nil)
        #expect(decided == 0, "the New Tab lists decided New Window's availability \(decided) times")
        #expect(first == second, "the catalog changed with state that is not a binding")
        #expect(second.contains { $0.id == "newWindow" }, "the catalog leaves out a bound row whose state is off now")
    }

    /// A binding change is what the catalog does depend on: a new shortcut shows on the next list (no stale keycaps).
    @Test func aShortcutChangeShowsInTheNextList() {
        let (services, registry) = Self.services()
        let before = Self.pageActions(services).first { $0.id == "newWindow" }?.keycaps
        registry.setShortcutOverride(Shortcut("j", modifiers: [.control, .option]), for: "newWindow")
        let after = Self.pageActions(services).first { $0.id == "newWindow" }?.keycaps
        #expect(after != before, "keycaps stayed \(String(describing: before)) after the shortcut changed")
        #expect(after?.contains("J") == true, "keycaps \(String(describing: after)) do not show the new key")
    }
}

/// Observable state a row's availability reads (``NewTabPaletteCatalogTests``).
@MainActor @Observable
final class PaletteCatalogGate {
    var open = true
}
