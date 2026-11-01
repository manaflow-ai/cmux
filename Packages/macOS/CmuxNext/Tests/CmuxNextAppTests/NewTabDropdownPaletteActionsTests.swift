@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import AppKit
import CmuxNextActions
import Testing

/// The New Tab page's dropdown lists every action the Commands palette (Cmd-Shift-P) lists
/// (Lawrence 2026-10-29: "make it so the dropdown has all the actions in cmd shift p"), from the
/// palette's own rows, not a second hand-kept list (it offered two actions before).
@MainActor
struct NewTabDropdownPaletteActionsTests {
    @Test func theDropdownOffersEveryCommandPaletteAction() {
        _ = NSApplication.shared // the palette's context reads NSApp's key window
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = services.registry
        registry.context = ActionContext(rawValue: .max)
        // Plain palette actions (no arguments), bound so the palette offers them.
        let ids = registry.descriptors.filter { $0.isPaletteVisible && !$0.isDebugOnly && $0.arguments.isEmpty }.map(\.id)
        for id in ids where !registry.isBound(id) { registry.bind(id) {} }
        let hidden = services.palette.hiddenActionIDs?() ?? []
        let runnable = ids.filter {
            $0 != "commandPalette" && !hidden.contains($0) && registry.isAvailable($0) && registry.canPerform($0)
                && registry.action(for: $0)?.paletteUnavailableReason?() == nil
        }
        #expect(runnable.count > AgentPaneOmnibar.maximumEntries)

        services.keyWindowSource = { nil }
        let offered = Set(NewTabPage.omnibar(services, excluding: nil).actions.map(\.id))
        let missing = runnable.filter { !offered.contains($0.rawValue) }
        #expect(missing.isEmpty, "the dropdown leaves out \(missing.count) of \(runnable.count) palette actions")
    }
}
