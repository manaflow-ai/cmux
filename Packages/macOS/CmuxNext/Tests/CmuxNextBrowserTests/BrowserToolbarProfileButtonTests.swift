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

    /// An incognito tab's button is its own disc (cmuxterm-hq RFD 0125, D1: "incognito (dark disc, incognito
    /// glyph)" and "never the generic glyph"): the incognito glyph on the primary-text plate, no letter.
    @Test func anIncognitoTabDrawsTheIncognitoDisc() throws {
        let buttons = toolbar(pins: ["profile"])
        let button = try #require(buttons.button(.profile) as? ChromeIconButton)
        buttons.profileBadge = BrowserProfileBadge(monogram: "W", color: .blue, name: "Work")
        buttons.profileBadge = .incognito(name: "Incognito")
        let avatar = try #require(buttons.profileAvatar)
        #expect(button.glyphReplacement === avatar, "the disc, not the plain person glyph")
        #expect(avatar.shownSymbol == "browser.incognito" && avatar.shownText.isEmpty)
        #expect(avatar.badge?.isIncognito == true)
        let header = BrowserProfileBadge.incognito(name: "Incognito").menuHeader(.builtIn)
        #expect(header.title == "Incognito" && header.subtitle == BrowserProfileStrings.incognitoReason && header.image != nil)
        // Back to a profile: its letter on its color again.
        buttons.profileBadge = BrowserProfileBadge(monogram: "W", color: .blue, name: "Work")
        #expect(avatar.shownText == "W" && avatar.shownSymbol == nil)
    }

    /// Every header has its reason line, the built-in default's too (RFD 0125, D2: "one line saying why this tab has it").
    @Test func everySourceHasAReasonLine() {
        let reasons = [BrowserProfileCascade.Source.workspace, .space, .tab, .builtIn].map(BrowserProfileStrings.reason)
        #expect(reasons.allSatisfy { !$0.isEmpty })
        #expect(Set(reasons).count == reasons.count)
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
}
