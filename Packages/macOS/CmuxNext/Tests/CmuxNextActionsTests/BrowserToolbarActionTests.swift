import CmuxNextActions
import Testing

/// The browser toolbar's five buttons each run a catalog action (R80), by
/// the names the toolbar spec gave them.
@MainActor
@Suite struct BrowserToolbarActionTests {
    static let toolbarIDs: [ActionID] = [
        "browser.designMode.toggle", "browser.profile.choose", "browser.theme.set", "browser.devtools.toggle", "browser.overflow.menu",
    ]

    @Test func everyToolbarActionIsACatalogEntry() throws {
        let registry = ActionRegistry.standard()
        for id in Self.toolbarIDs {
            let descriptor = try #require(registry.descriptor(for: id), "\(id)")
            #expect(descriptor.category == .browser, "\(id)")
            #expect(descriptor.requires.contains(.browserFocused), "\(id)")
            #expect(descriptor.isPaletteVisible, "\(id)")
            #expect(!descriptor.title.isEmpty, "\(id)")
        }
    }

    /// The design mode, theme and DevTools buttons share the existing
    /// actions (their shortcuts and `cmux.json` ids stay); the spec's names
    /// are aliases.
    @Test func togglesShareTheExistingActions() {
        let registry = ActionRegistry.standard()
        #expect(registry.canonicalID(for: "browser.designMode.toggle") == "toggleBrowserDesignMode")
        #expect(registry.canonicalID(for: "browser.devtools.toggle") == "toggleBrowserDeveloperTools")
        #expect(registry.canonicalID(for: "browser.theme.set") == "browserTheme")
        #expect(registry.canonicalID(for: "browser.profile.choose") == "browser.profile.choose")
        #expect(registry.canonicalID(for: "browser.overflow.menu") == "browser.overflow.menu")
    }

    @Test func themeSetOffersEachMode() throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: "browser.theme.set"))
        let argument = try #require(descriptor.arguments.first { $0.name == "theme" })
        guard case .enumeration(let cases) = argument.kind else {
            Issue.record("theme is not an enumeration")
            return
        }
        #expect(cases.map(\.value) == ["system", "light", "dark"])
    }

    /// The two menu actions open a menu at their button: no CLI verb and no
    /// right-click placement, each with its reason.
    @Test func menuActionsDeclareTheirSurfaces() throws {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["browser.profile.choose", "browser.overflow.menu"] {
            let plan = try #require(registry.descriptor(for: id)).surfacePlan
            #expect(plan.cli == .exempt(.guiOnly), "\(id)")
            #expect(plan.contextMenus.isEmpty && plan.contextMenuExemption == .guiOnly, "\(id)")
        }
    }
}
