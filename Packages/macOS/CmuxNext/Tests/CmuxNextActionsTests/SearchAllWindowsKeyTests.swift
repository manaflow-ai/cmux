import AppKit
import CmuxNextActions
import Testing

/// Opt-Cmd-F is Search All Windows everywhere, a browser tab included: a default key moves only
/// with the user's OK. Search the Web (`browser.focusSearch`) has no default key and stays in the
/// palette.
@MainActor @Suite struct SearchAllWindowsKeyTests {
    private func resolve(in context: ActionContext) throws -> String? {
        // The app binds a handler to every catalog action; a key runs only a bound one.
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        registry.context = context
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
        ))
        return registry.resolveShortcut(for: event)?.id.rawValue
    }

    @Test func optionCommandFSearchesAllWindowsInABrowserTab() throws {
        #expect(try resolve(in: [.browserFocused]) == "globalSearch")
    }

    @Test func optionCommandFSearchesAllWindowsElsewhere() throws {
        #expect(try resolve(in: []) == "globalSearch")
    }

    @Test func searchTheWebHasNoDefaultKeyAndStaysInThePalette() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == "browser.focusSearch" })
        #expect(descriptor.defaultShortcut == nil)
        #expect(descriptor.surfaces.contains(.palette))
    }
}
