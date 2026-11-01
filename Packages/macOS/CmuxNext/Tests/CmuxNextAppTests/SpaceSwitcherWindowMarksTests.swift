import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The space switcher marks the spaces other windows show and offers Go to Window / Move Here on them
/// (design/spaces.md "The switcher (PR 3)", `sidebar.spaceSwitcher`). Leo 2026-10-29: "this could legit make our thing
/// more useful than chrome by having windows be switchable in this way". Incognito never mixes with normal content.
@MainActor @Suite(.serialized, .closesItsWindows) struct SpaceSwitcherWindowMarksTests {
    static let keys = (0..<3).map { ProfileKey("space\($0)") }

    // MARK: Which spaces other windows show

    @Test func otherWindowsSpacesAreListedWithTheFrontmostWindow() {
        let windows = [
            SpaceWindowShowing(windowID: "front", space: Self.keys[1]),
            SpaceWindowShowing(windowID: "here", space: Self.keys[0]),
            SpaceWindowShowing(windowID: "back", space: Self.keys[1]),
            SpaceWindowShowing(windowID: "incognito", space: Self.keys[2], incognito: true),
        ]
        let shown = SpaceSwitcherLogic.shownElsewhere(windows, here: "here")
        #expect(shown[Self.keys[0]] == nil, "this window's own space is not elsewhere")
        #expect(shown[Self.keys[1]] == SpaceElsewhere(windowID: "front", incognito: false), "the frontmost window wins")
        #expect(shown[Self.keys[2]] == SpaceElsewhere(windowID: "incognito", incognito: true))
    }

    @Test func aSpaceThisWindowAlsoShowsIsStillMarkedWhenAnotherWindowShowsIt() {
        let shown = SpaceSwitcherLogic.shownElsewhere([SpaceWindowShowing(windowID: "here", space: Self.keys[0]),
                                                       SpaceWindowShowing(windowID: "other", space: Self.keys[0])], here: "here")
        #expect(shown[Self.keys[0]]?.windowID == "other")
    }

    @Test func moveHereIsNeverOfferedAcrossIncognito() {
        let normal = SpaceElsewhere(windowID: "w", incognito: false), incognito = SpaceElsewhere(windowID: "w", incognito: true)
        #expect(SpaceSwitcherLogic.choices(for: normal, hereIsIncognito: false) == [.goToWindow, .moveHere])
        #expect(SpaceSwitcherLogic.choices(for: incognito, hereIsIncognito: false) == [.goToWindow])
        #expect(SpaceSwitcherLogic.choices(for: normal, hereIsIncognito: true) == [.goToWindow])
    }

    @Test func aClickOffersTheChoicesOptionGoesAndPlainSwitches() {
        let other = SpaceElsewhere(windowID: "w", incognito: false)
        func click(_ style: SpaceSwitcherStyle, _ space: ProfileKey, option: Bool = false, elsewhere: SpaceElsewhere? = other) -> SpaceClick {
            SpaceSwitcherLogic.click(space, active: Self.keys[0], elsewhere: elsewhere, hereIsIncognito: false, style: style, option: option)
        }
        #expect(click(.ring, Self.keys[1]) == .offer([.goToWindow, .moveHere]))
        #expect(click(.ring, Self.keys[1], option: true) == .goToWindow)
        #expect(click(.ring, Self.keys[1], elsewhere: nil) == .switchHere, "a space no other window shows switches as before")
        #expect(click(.plain, Self.keys[1]) == .switchHere, "plain is today's strip")
        #expect(click(.plain, Self.keys[1], option: true) == .switchHere)
        #expect(click(.ring, Self.keys[0]) == .none)
        #expect(click(.menu, Self.keys[0]) == .spaceMenu)
        #expect(SpaceSwitcherStyle.tunable.defaultValue == .ring, "the gallery's pick is the default for the new marker only")
    }

    // MARK: The bar

    final class Bar {
        let model = SidebarModel()
        let view: ProfileBarView
        let window: NSWindow
        var intents: [SidebarIntent] = []
        var menus: [NSMenu] = []
        var opens: [Bool] = []
        /// The mark lit while its menu was open.
        var litWhileOpen: Int?

        init(style: SpaceSwitcherStyle) {
            model.profiles = SpaceSwitcherWindowMarksTests.keys.enumerated().map { SidebarProfile(id: $1, name: "Space \($0)") }
            model.activeProfileID = SpaceSwitcherWindowMarksTests.keys[0]
            model.spacesElsewhere = [SpaceSwitcherWindowMarksTests.keys[1]: SpaceElsewhere(windowID: "other", incognito: false)]
            view = ProfileBarView(model: model)
            view.switcherStyleOverride = style
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.refresh()
            model.onIntent = { [weak self] intent in self?.intents.append(intent) }
            view.onMenuOpenChange = { [weak self] open in self?.opens.append(open) }
            view.presentMenu = { [weak self] menu, _ in
                guard let self else { return }
                self.menus.append(menu)
                self.view.setHovered(nil) // the pointer leaves while the menu is open
                self.litWhileOpen = self.view.hovered
            }
        }

        func click(_ index: Int, option: Bool = false) {
            let slot = view.slotRects()[index], point = NSPoint(x: slot.midX, y: slot.midY)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: option ? [.option] : [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown))
            view.mouseUp(with: event(.leftMouseUp))
        }

        func choose(_ title: String, in menu: NSMenu) {
            (menu.items.first { $0.title == title } as? SwitcherMenuItem)?.fire()
        }
    }

    @Test func clickingAnotherWindowsSpaceOffersGoToWindowAndMoveHere() throws {
        let bar = Bar(style: .ring)
        defer { bar.window.closeAfterTest() }
        bar.click(1)
        let menu = try #require(bar.menus.first, "no menu opened: \(bar.intents)")
        #expect(menu.items.map(\.title) == [Strings.goToSpaceWindow, Strings.moveSpaceHere])
        #expect(bar.intents.isEmpty, "a click on another window's space switched at once: \(bar.intents)")
        #expect(bar.opens == [true, false], "the sidebar chrome was not held revealed while the menu was open")
        #expect(bar.litWhileOpen == 1, "the mark did not stay lit while its menu was open")
        bar.choose(Strings.moveSpaceHere, in: menu)
        bar.choose(Strings.goToSpaceWindow, in: menu)
        #expect(bar.intents == [.bringSpaceHere(Self.keys[1]), .goToSpaceWindow(Self.keys[1])])
    }

    @Test func optionClickGoesToThatWindow() {
        let bar = Bar(style: .ring)
        defer { bar.window.closeAfterTest() }
        bar.click(1, option: true)
        #expect(bar.menus.isEmpty)
        #expect(bar.intents == [.goToSpaceWindow(Self.keys[1])])
    }

    @Test func aSpaceNoOtherWindowShowsAndThePlainStripStillSwitch() {
        let ring = Bar(style: .ring), plain = Bar(style: .plain)
        defer { ring.window.closeAfterTest(); plain.window.closeAfterTest() }
        ring.click(2)
        plain.click(1)
        #expect(ring.intents == [.switchProfile(Self.keys[2])] && ring.menus.isEmpty)
        #expect(plain.intents == [.switchProfile(Self.keys[1])] && plain.menus.isEmpty)
    }

    @Test func anIncognitoSpaceOffersOnlyGoToWindow() throws {
        let bar = Bar(style: .ring)
        defer { bar.window.closeAfterTest() }
        bar.model.spacesElsewhere = [Self.keys[1]: SpaceElsewhere(windowID: "incognito", incognito: true)]
        bar.click(1)
        #expect(try #require(bar.menus.first).items.map(\.title) == [Strings.goToSpaceWindow])
    }

    @Test func theSpaceMenuListsEverySpaceAndEndsWithNewSpaces() throws {
        let bar = Bar(style: .menu)
        defer { bar.window.closeAfterTest() }
        bar.click(0)
        let menu = try #require(bar.menus.first)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Space 0", Strings.spaceInAnotherWindow("Space 1"), "Space 2", Strings.newProfile, Strings.newIncognitoSpace])
        #expect(menu.items[0].state == .on, "the current space is not checked")
        #expect(menu.items[1].submenu?.items.map(\.title) == [Strings.goToSpaceWindow, Strings.moveSpaceHere])
        bar.choose("Space 2", in: menu)
        bar.choose(Strings.newIncognitoSpace, in: menu)
        #expect(bar.intents == [.switchProfile(Self.keys[2]), .newIncognitoSpace])
    }

    @Test func theMarkSaysAnotherWindowShowsTheSpace() {
        let bar = Bar(style: .ring)
        defer { bar.window.closeAfterTest() }
        let labels = (bar.view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(labels.contains(Strings.spaceInAnotherWindow("Space 1")), "\(labels)")
        #expect(labels.contains("Space 2"))
    }
}
