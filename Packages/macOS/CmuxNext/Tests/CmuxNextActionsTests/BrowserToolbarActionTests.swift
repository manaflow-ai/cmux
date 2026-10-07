import CmuxNextActions
import Testing

/// The browser toolbar's five buttons each run a catalog action (R80): one
/// action id per behavior.
@MainActor
@Suite struct BrowserToolbarActionTests {
    static let toolbarIDs: [ActionID] = [
        "toggleBrowserDesignMode", "browser.profile.choose", "browserTheme", "toggleBrowserDeveloperTools", "browser.overflow.menu",
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

    /// Design mode, theme and DevTools reuse the existing actions (their
    /// shortcuts and `cmux.json` ids stay); no second id names them.
    @Test func togglesAreTheExistingActionsWithoutAliases() {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["browser.designMode.toggle", "browser.devtools.toggle", "browser.theme.set"] {
            #expect(registry.descriptor(for: id) == nil, "\(id)")
        }
        for id in Self.toolbarIDs { #expect(registry.canonicalID(for: id) == id, "\(id)") }
    }

    @Test func browserThemeOffersEachMode() throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: "browserTheme"))
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
