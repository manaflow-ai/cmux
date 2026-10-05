import CmuxNextActions
import CmuxNextSettings
@testable import CmuxNextSettingsWindow
import Testing

/// Deep links into the React Settings page (`openSettings section: setting:`): a key resolves to
/// its section and anchor, the arguments parse, and every section's buttons are catalog actions.
@MainActor
@Suite struct SettingsDeepLinkTests {
    @Test func keysResolveToTheirSectionAndAnchor() {
        let speed = SettingsAnchor(key: "ui.animationSpeed")
        #expect(speed == SettingsAnchor(section: .appearance, id: "ui.animationSpeed"))
        #expect(SettingsAnchor(key: "  ui.animationSpeed\n") == speed)
        #expect(SettingsAnchor(key: "theme") == SettingsAnchor(section: .appearance, id: "card.theme"))
        #expect(SettingsAnchor(key: "card.machines") == SettingsAnchor(section: .machines, id: "card.machines"))
        #expect(SettingsAnchor(key: "importFromBrowser")
            == SettingsAnchor(section: .browser, id: "action.browser.importFromBrowser"))
        // A button on two pages: the bare id opens the first, the anchor id its own.
        #expect(SettingsAnchor(key: "palette.openGhosttySettings")?.section == .appearance)
        #expect(SettingsAnchor(key: "action.terminal.palette.openGhosttySettings")?.section == .terminal)
        let header = SettingsAnchor(key: "section.keyboard")
        #expect(header?.isHeader == true && header?.section == .keyboard)
        #expect(SettingsAnchor(key: "no.such.setting") == nil)
        #expect(SettingsAnchor(key: "   ") == nil)
    }

    @Test func theSettingArgumentParses() throws {
        let link = SettingsDeepLink(ActionInvocation(arguments: ["section": .string("keyboard"), "setting": .string("  ui.animationSpeed ")]))
        #expect(link == SettingsDeepLink(section: .keyboard, setting: "ui.animationSpeed"))
        #expect(link.anchor == SettingsAnchor(section: .appearance, id: "ui.animationSpeed"))
        #expect(SettingsDeepLink(ActionInvocation()) == SettingsDeepLink())
        #expect(SettingsDeepLink(ActionInvocation(arguments: ["setting": .string("  ")])).setting == nil)
        #expect(SettingsDeepLink(ActionInvocation(arguments: ["section": .string("nope")])).section == nil)
        let unknown = SettingsDeepLink(ActionInvocation(arguments: ["setting": .string("no.such.setting")]))
        #expect(unknown.setting == "no.such.setting" && unknown.anchor == nil)

        // `cmux action run openSettings --arg setting=<key>` is optional text.
        let descriptor = try #require(ActionRegistry(catalog: ActionCatalog.all).descriptor(for: "openSettings"))
        let argument = try #require(descriptor.arguments.first { $0.name == "setting" })
        #expect(argument.kind == .string && !argument.isRequired)
        #expect(argument.parse("tabs.newTabKind") == .string("tabs.newTabKind"))
    }

    @Test func everySectionTitleAndActionIsKnown() {
        let catalog = ActionRegistry(catalog: ActionCatalog.all)
        for section in SettingsSection.allCases {
            #expect(!section.title.isEmpty)
            for id in SettingsSchema.actions(in: section) {
                #expect(catalog.descriptor(for: id) != nil, "\(section): \(id.rawValue)")
            }
        }
    }

    /// `cmux action run openSettings --arg section=keyboard` names the same sections the page shows.
    @Test func openSettingsSectionsAreThePageSections() throws {
        let descriptor = try #require(ActionRegistry(catalog: ActionCatalog.all).descriptor(for: "openSettings"))
        let argument = try #require(descriptor.arguments.first { $0.name == "section" })
        guard case .enumeration(let cases) = argument.kind else {
            Issue.record("section is not an enumeration")
            return
        }
        #expect(cases.map(\.value) == SettingsSection.allCases.map(\.rawValue))
        #expect(!argument.isRequired)
    }
}
