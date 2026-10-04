import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextControl
import Testing

/// Every browser toolbar button runs a bound catalog action (R80).
@MainActor
struct BrowserToolbarBindingTests {
    @Test func everyButtonRunsABoundAction() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        for button in BrowserToolbarButton.allCases {
            let id = BrowserToolbarHandlers.actionID(for: button)
            #expect(registry.descriptor(for: id) != nil, "\(button): \(id)")
            #expect(registry.isBound(id), "\(button): \(id)")
        }
    }

    @Test func buttonsRunOneActionPerBehavior() {
        let ids = BrowserToolbarButton.allCases.map { BrowserToolbarHandlers.actionID(for: $0).rawValue }
        #expect(ids == ["toggleBrowserDesignMode", "browser.profile.choose", "browserTheme", "toggleBrowserDeveloperTools",
                        "browser.overflow.menu"])
    }

    @Test(arguments: [("light", BrowserColorScheme.light), ("dark", .dark), ("system", .system), ("sepia", .system)])
    func browserThemeReadsEachMode(value: String, scheme: BrowserColorScheme) {
        #expect(BrowserToolbarHandlers.colorScheme(ActionInvocation(arguments: ["theme": .string(value)])) == scheme)
    }

    @Test func browserThemeWithoutAModeFollowsTheApp() {
        #expect(BrowserToolbarHandlers.colorScheme(ActionInvocation()) == .system)
    }

    /// From the palette or `cmux action run` with no browser page focused,
    /// each action refuses with the reason instead of doing nothing.
    @Test func toolbarActionsRefuseWithoutABrowser() {
        let services = ActionBindingCoverageTests.boundServices()
        services.registry.context = [.browserFocused]
        for id in ["browser.profile.choose", "browser.overflow.menu", "toggleBrowserDesignMode", "toggleBrowserDeveloperTools"] {
            #expect(ActionBindingCoverageTests.run(services, id) == .refused(MiscHandlerStrings.noBrowser), "\(id)")
        }
    }
}
