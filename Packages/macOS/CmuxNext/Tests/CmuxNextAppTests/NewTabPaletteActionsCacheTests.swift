@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import AppKit
import CmuxNextActions
import CmuxNextHomeEngine
import Observation
import Testing

/// Every Cmd-T built the New Tab dropdown's copy of the Commands palette again on the frame
/// after the page showed (`NewTabPage.fillPaletteActions` -> `PaletteController.commandEntries`
/// -> `RegistryPaletteProvider.makeItems`). In the STRESS session Cmd-T took 83.5 ms p95 to its
/// committed frame, and its longest main-thread stall (131 ms) was this build (every-action sweep,
/// fleet job 59b1063a51893f653d11cfc6, feat 038bf00cc91, bench build). The list changes only when
/// what it reads changes (the registry's bindings, catalog, shortcuts, context), so it is built
/// once per change and every page takes the same list.
@MainActor
struct NewTabPaletteActionsCacheTests {
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

    /// Counts the builds through a row's palette title, which every build reads once.
    private static func countBuilds(of id: ActionID, in registry: ActionRegistry, title: @escaping @MainActor () -> String = { "Probe" }) -> () -> Int {
        final class Counter { var builds = 0 }
        let counter = Counter()
        ActionTargetTitles.setPaletteTitle(id, in: registry) {
            counter.builds += 1
            return title()
        }
        return { counter.builds }
    }

    @Test func aSecondNewTabTakesTheListBuiltForTheFirst() {
        let (services, registry) = Self.services()
        let builds = Self.countBuilds(of: "newWindow", in: registry)
        let first = NewTabPage.paletteActions(services)
        let second = NewTabPage.paletteActions(services)
        #expect(builds() == 1, "the dropdown's list was built \(builds()) times for two New Tab pages with nothing changed")
        #expect(first == second)
        #expect(first.contains { $0.id == "newWindow" })
    }

    @Test func aChangeToWhatTheListReadsBuildsItAgain() {
        let (services, registry) = Self.services()
        let before = Self.countBuilds(of: "newWindow", in: registry) { "Before" }
        _ = NewTabPage.paletteActions(services)
        _ = NewTabPage.paletteActions(services)
        #expect(before() == 1)
        // A binding changed (the row's title now reads otherwise): the next page gets a list built after it.
        let after = Self.countBuilds(of: "newWindow", in: registry) { "After" }
        let list = NewTabPage.paletteActions(services)
        #expect(after() == 1, "the list was not built again after the registry changed")
        #expect(list.first { $0.id == "newWindow" }?.title == "After")
    }

    /// A row's availability that reads observable app state: its first change drops the kept list, so the
    /// dropdown never offers a row that cannot run (the cache watches everything a build read).
    @Test func aRowThatTurnsUnavailableLeavesTheNextList() {
        let (services, registry) = Self.services()
        let gate = PaletteRowGate()
        registry.bind("newWindow", isEnabled: { gate.open }) {}
        #expect(NewTabPage.paletteActions(services).contains { $0.id == "newWindow" })
        gate.open = false
        #expect(!NewTabPage.paletteActions(services).contains { $0.id == "newWindow" }, "the dropdown still offers a row that cannot run")
        gate.open = true
        #expect(NewTabPage.paletteActions(services).contains { $0.id == "newWindow" })
    }

    /// The Chief's Stop All Agents row asks which window is in front on every palette build
    /// (`HomeChiefSettingsPopover.frontToggleTarget`). With a key window that is the answer:
    /// the window server's front-to-back list (a mach round trip, up to 40 ms in the trace) is
    /// read only when no window has the keys.
    @Test func theFrontWindowWithAKeyWindowNeverAsksTheWindowServer() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        var asked = 0
        func ordered() -> [NSWindow] {
            asked += 1
            return []
        }
        #expect(HomeChiefSettingsPopover.toggleTarget(key: window, ordered: ordered()) === window)
        #expect(asked == 0, "read the window order \(asked) times with a key window")
        #expect(HomeChiefSettingsPopover.toggleTarget(key: nil, ordered: ordered()) == nil)
        #expect(asked == 1)
    }
}

/// Observable state a row's availability reads (``NewTabPaletteActionsCacheTests/aRowThatTurnsUnavailableLeavesTheNextList()``).
@MainActor @Observable
final class PaletteRowGate {
    var open = true
}
