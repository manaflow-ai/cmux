@testable import CmuxNextActions
import Testing

/// Each Cmd-Shift-P read every catalog action's keycaps, and each read scanned every shortcut override and
/// alternate (`LeaderLayer.defaultChord`): quadratic in the catalog, on every open (a 1 ms sample of 40 opens,
/// cmux11s: `shortcutKeycaps` the largest single cost of the per-action reads). The keycaps change only when a
/// binding changes, which already drops the registry's shortcut index, so they are kept there.
@MainActor
struct ShortcutKeycapsCacheTests {
    private func shortcutAction(_ registry: ActionRegistry) throws -> ActionID {
        try #require(registry.descriptors.map(\.id).first { registry.shortcutKeycaps(for: $0) != nil },
                     "the catalog has no action with a shortcut")
    }

    @Test func readingTheKeycapsAgainBuildsNothing() throws {
        let registry = ActionRegistry.standard()
        let id = try shortcutAction(registry)
        let builds = registry.keycapsBuilds
        let first = registry.shortcutKeycaps(for: id)
        for _ in 0..<5 { #expect(registry.shortcutKeycaps(for: id) == first) }
        #expect(registry.keycapsBuilds == builds, "a read with no binding changed built the keycaps again")
    }

    /// A changed binding shows at once: the override drops the kept keycaps.
    @Test func anOverrideShowsItsNewKeycaps() throws {
        let registry = ActionRegistry.standard()
        let id = try shortcutAction(registry)
        _ = registry.shortcutKeycaps(for: id)
        registry.setShortcutOverride(Shortcut("k", modifiers: [.command, .option, .control]), for: id)
        #expect(registry.shortcutKeycaps(for: id) == ["⌃", "⌥", "⌘", "K"])
        registry.setShortcutOverride(nil, for: id)
        #expect(registry.shortcutKeycaps(for: id) == nil, "an unbound action kept its old keycaps")
    }
}
