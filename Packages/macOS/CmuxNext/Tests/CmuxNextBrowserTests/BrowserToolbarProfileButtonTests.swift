import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The tab's browser profile is a toolbar button, at the toolbar's right, last before More, outside the
/// address bar (Leo 2026-11-22: "why do we have the profile icon here if it's always visible ... move it
/// outside the omnibar like a normal ... browser ... have their profiles on the right"; cmuxterm-hq RFD
/// 0050, D1). It draws the profile's avatar in place of the plain person glyph.
@MainActor @Suite struct BrowserToolbarProfileButtonTests {
    private func toolbar(pins: [String]) -> BrowserToolbarButtonsView {
        let buttons = BrowserToolbarButtonsView()
        buttons.pins = { pins }
        return buttons
    }

    @Test func theProfileButtonIsTheLastBeforeMore() {
        let order = BrowserToolbarButton.allCases
        #expect(order.suffix(2) == [.profile, .overflow])
        let buttons = toolbar(pins: BrowserToolbarButton.pinnable.map(\.rawValue))
        let shown = buttons.arrangedSubviews.filter { !$0.isHidden }.map { $0.accessibilityIdentifier() }
        #expect(shown.suffix(2) == [BrowserToolbarButton.profile.identifier, BrowserToolbarButton.overflow.identifier], "\(shown)")
    }

    @Test func theProfileButtonDrawsTheProfilesAvatar() throws {
        let buttons = toolbar(pins: ["profile"])
        let button = try #require(buttons.button(.profile) as? ChromeIconButton, "the pinned profile button was not made")
        #expect(button.glyphReplacement == nil, "no profile yet: the plain glyph")
        buttons.profileBadge = BrowserProfileBadge(monogram: "W", color: nil, name: "Work")
        let avatar = try #require(buttons.profileAvatar)
        #expect(button.glyphReplacement === avatar)
        #expect(avatar.shownText == "W")
        #expect(avatar.superview === button)
        // The button, not the avatar, takes the press.
        #expect(avatar.hitTest(NSPoint(x: 1, y: 1)) == nil)
        // The disc fits inside the button with room for the hover fill around it.
        #expect(avatar.side >= 16 && avatar.side <= OmnibarStyle.buttonSize - 4, "side \(avatar.side) in a \(OmnibarStyle.buttonSize) button")

        buttons.profileBadge = BrowserProfileBadge(monogram: "person.fill", color: nil, name: "Me")
        #expect(avatar.shownSymbol == "person.fill" && avatar.shownText.isEmpty)

        // An incognito tab has no profile: the plain glyph again.
        buttons.profileBadge = nil
        #expect(button.glyphReplacement == nil)
        #expect(avatar.superview == nil)
    }

    /// The avatar set before the button exists (a tab bound while the button is unpinned) shows once it is pinned.
    @Test func aProfileSetBeforeTheButtonShowsOnceItIsPinned() throws {
        var pins: [String] = []
        let buttons = BrowserToolbarButtonsView()
        buttons.pins = { pins }
        buttons.profileBadge = BrowserProfileBadge(monogram: "D", color: nil, name: "Default")
        #expect(buttons.button(.profile) == nil)
        pins = ["profile"]
        buttons.refresh()
        let button = try #require(buttons.button(.profile) as? ChromeIconButton)
        #expect(button.glyphReplacement === buttons.profileAvatar && buttons.profileAvatar?.shownText == "D")
    }

    /// Why a tab has its profile (the profile menu's header line).
    @Test func theCascadeNamesWhyATabHasItsProfile() {
        let known: (String) -> Bool = { ["default", "work", "play"].contains($0) }
        func source(_ tab: String?, workspace: String? = nil, room: String? = nil) -> BrowserProfileCascade.Source {
            BrowserProfileCascade.source(tabProfile: tab, workspace: workspace, room: room, known: known)
        }
        #expect(source(nil) == .builtIn)
        #expect(source("default") == .builtIn)
        #expect(source("work") == .tab)
        #expect(source("work", workspace: "work") == .workspace)
        #expect(source("work", workspace: "play") == .tab)
        #expect(source("work", room: "work") == .space)
        #expect(source("work", workspace: "play", room: "work") == .tab, "the workspace's default stands before the space's")
        #expect(source("default", workspace: "gone", room: "") == .builtIn, "a deleted or blank default names nothing")
        #expect(source("default", room: "work") == .tab)
    }

    /// The default level shows the button only while it says something (design-propose dp-863111dbbf: the
    /// subtle form of RFD 0050 D1): a second profile of the person's own, an incognito tab, the Agents
    /// profile. `always` and `color` show it in every pane.
    @Test func theQuietLevelShowsTheButtonOnlyWhenItSaysSomething() {
        func shown(_ alwaysShown: Bool = false, profiles: Int = 1, incognito: Bool = false, agents: Bool = false) -> Bool {
            BrowserProfileButtonPresence.resolve(alwaysShown: alwaysShown, colored: false, personProfiles: profiles,
                                                 incognito: incognito, agentsProfile: agents).shown
        }
        #expect(!shown(), "one profile: nothing to say")
        #expect(shown(profiles: 2))
        #expect(shown(incognito: true))
        #expect(shown(agents: true))
        #expect(shown(true), "the always level")
    }

    @Test func aHiddenPresenceTakesThePinnedButtonOutOfTheRow() throws {
        var presence = BrowserProfileButtonPresence(shown: false, colored: false)
        let buttons = toolbar(pins: ["profile"])
        buttons.profilePresence = { presence }
        let visible = { buttons.arrangedSubviews.filter { !$0.isHidden }.map { $0.accessibilityIdentifier() } }
        #expect(!visible().contains(BrowserToolbarButton.profile.identifier), "\(visible())")
        presence.shown = true
        buttons.refresh()
        #expect(visible().contains(BrowserToolbarButton.profile.identifier), "\(visible())")
    }

    /// Hue is the agent driver's ring: the avatar draws in the toolbar's ink unless the person chose `color`.
    @Test func theAvatarIsInkUnlessThePersonChoseColor() throws {
        var presence = BrowserProfileButtonPresence(shown: true, colored: false)
        let buttons = toolbar(pins: ["profile"])
        buttons.profilePresence = { presence }
        buttons.profileBadge = BrowserProfileBadge(monogram: "W", color: .blue, name: "Work")
        let avatar = try #require(buttons.profileAvatar)
        #expect(avatar.badge?.color == nil)
        #expect(avatar.shownText == "W")
        presence.colored = true
        buttons.refresh()
        #expect(buttons.profileAvatar?.badge?.color == .blue)
    }
}
