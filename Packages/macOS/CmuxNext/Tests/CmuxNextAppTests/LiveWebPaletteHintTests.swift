import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Leo, 2026-11-07, on the live loop in the app: "have that little bit in the GUI as a sort of like,
/// hey, you can do this, man, and you can get your agent to do this". Edit cmux Live… says what it
/// does in one line under its title, and the line is the action's own (``ActionDescriptor/hint``).
@MainActor @Suite(.serialized, .closesItsWindows)
struct LiveWebPaletteHintTests {
    @Test func editCmuxLiveSaysWhatItDoesUnderItsTitle() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let descriptor = try #require(services.registry.descriptor(for: "liveWeb.start"))
        let hint = try #require(descriptor.hint)
        #expect(hint.contains("agent"))
        let items = RegistryPaletteProvider(registry: services.registry).makeItems()
        // A row that cannot run here is not listed; one that runs says what it does.
        if let row = items.first(where: { $0.id == "action:liveWeb.start" }) { #expect(row.subtitle == hint) }
        // Actions with no hint keep no subtitle while they run.
        if let other = items.first(where: { $0.id == "action:liveWeb.stop" }) { #expect(other.subtitle == nil) }
    }
}
